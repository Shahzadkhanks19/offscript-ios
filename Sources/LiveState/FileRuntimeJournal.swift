import Foundation

/// Foundation-only persistent implementation of RuntimeJournal.
///
/// The entire journal snapshot is encoded to a temporary file and atomically
/// replaced on every mutation. This deliberately favors correctness and a
/// dependency-free M1 implementation over write throughput. A database-backed
/// journal can replace it later without changing EncounterRuntime.
public actor FileRuntimeJournal: RuntimeJournal {
    private struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int = currentSchemaVersion
        var events: [EventRecord] = []
        var intents: [UUID: DurableEffectIntent] = [:]
        var results: [UUID: SimulationEvent] = [:]
        var completedIntentIDs: Set<UUID> = []
    }

    public enum StorageError: Error, Equatable, Sendable {
        case unsupportedSchema(Int)
        case corruptStore
    }

    private let fileURL: URL
    private var snapshot: Snapshot

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.snapshot = try Self.load(from: fileURL)
    }

    public func commit(
        event: EventRecord,
        intents newIntents: [DurableEffectIntent],
        completing intentID: UUID?
    ) async throws {
        var next = snapshot

        if let existing = next.events.first(where: { $0.id == event.id }) {
            guard existing == event else {
                throw RuntimeJournalError.eventConflict(id: event.id)
            }
            // Exact event replay is allowed, but the transaction still needs
            // validation below so conflicting outbox work cannot hide behind it.
        }

        if let encounterID = event.encounterID,
           let existing = next.events.first(where: {
               $0.encounterID == encounterID && $0.sequence == event.sequence
           }) {
            guard existing == event else {
                throw RuntimeJournalError.sequenceConflict(
                    encounterID: encounterID,
                    sequence: event.sequence
                )
            }
        }

        for intent in newIntents {
            if let existing = next.intents[intent.id] {
                guard existing == intent else {
                    throw RuntimeJournalError.intentConflict(id: intent.id)
                }
            }
        }

        if !next.events.contains(where: { $0.id == event.id }) {
            next.events.append(event)
        }

        if let intentID {
            next.intents.removeValue(forKey: intentID)
            next.results.removeValue(forKey: intentID)
            next.completedIntentIDs.insert(intentID)
        }

        for intent in newIntents where !next.completedIntentIDs.contains(intent.id) {
            next.intents[intent.id] = intent
        }

        try persist(next)
        snapshot = next
    }

    public func records(encounterID: UUID) async throws -> [EventRecord] {
        snapshot.events
            .filter { $0.encounterID == encounterID }
            .sorted { $0.sequence < $1.sequence }
    }

    public func pendingIntents(encounterID: UUID) async throws -> [DurableEffectIntent] {
        snapshot.intents.values
            .filter { $0.encounterID == encounterID }
            .sorted {
                if $0.originatingSequence == $1.originatingSequence {
                    return $0.effectIndex < $1.effectIndex
                }
                return $0.originatingSequence < $1.originatingSequence
            }
    }

    public func markCompleted(intentID: UUID) async throws {
        var next = snapshot
        next.intents.removeValue(forKey: intentID)
        next.results.removeValue(forKey: intentID)
        next.completedIntentIDs.insert(intentID)
        try persist(next)
        snapshot = next
    }

    public func result(for intentID: UUID) async throws -> SimulationEvent? {
        snapshot.results[intentID]
    }

    public func saveResult(_ event: SimulationEvent, for intentID: UUID) async throws {
        guard let intent = snapshot.intents[intentID] else {
            throw RuntimeJournalError.resultForUnknownIntent(intentID: intentID)
        }
        try DurableResultValidator.validate(event, for: intent)

        if let existing = snapshot.results[intentID] {
            guard existing == event else {
                throw RuntimeJournalError.resultConflict(intentID: intentID)
            }
            return
        }

        var next = snapshot
        next.results[intentID] = event
        try persist(next)
        snapshot = next
    }

    private static func load(from url: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Snapshot()
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            guard decoded.schemaVersion == Snapshot.currentSchemaVersion else {
                throw StorageError.unsupportedSchema(decoded.schemaVersion)
            }
            return decoded
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.corruptStore
        }
    }

    private func persist(_ value: Snapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            // The temporary file lives beside the destination so the final
            // rename stays on the same volume. Foundation's replaceItemAt is
            // not implemented on Windows, so use POSIX-style rename where
            // available; Windows falls back to remove + move. The snapshot is
            // still fully encoded before the destination is touched.
            try data.write(to: temporaryURL, options: .atomic)

            #if os(Windows)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            #else
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
            #endif
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
