import Foundation

public struct RecordedEvent: Equatable, Sendable {
    public let sequence: Int
    public let event: SimulationEvent
    public init(sequence: Int, event: SimulationEvent) { self.sequence = sequence; self.event = event }
    public init(_ record: EventRecord) { self.sequence = record.sequence; self.event = record.event }
}

public enum ReplayValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(found: Int, supported: Int)
    case encounterMismatch(expected: UUID, found: UUID)
    case duplicateSequence(Int)
    case sequenceGap(expected: Int, found: Int)
    case staleSequence(expectedAtLeast: Int, found: Int)
}

public enum ReplayEngine {
    public static func replay(initial: EncounterState, events: [RecordedEvent]) -> EncounterState {
        events.sorted { $0.sequence < $1.sequence }.reduce(initial) { state, record in
            LiveStateReducer.reduce(state: state, event: record.event).state
        }
    }

    /// Validates persisted envelopes before applying them. Legacy schema-v1
    /// records remain replayable because encounter/branch identity was not
    /// persisted until schema v2.
    public static func validatedReplay(
        initial: EncounterState,
        records: [EventRecord]
    ) throws -> EncounterState {
        let ordered = records.sorted { $0.sequence < $1.sequence }
        var expected = initial.sequence + 1
        var previousSequence: Int?

        for record in ordered {
            guard record.schemaVersion <= EventRecord.currentSchemaVersion else {
                throw ReplayValidationError.unsupportedSchema(
                    found: record.schemaVersion,
                    supported: EventRecord.currentSchemaVersion
                )
            }
            if let encounterID = record.encounterID, encounterID != initial.id {
                throw ReplayValidationError.encounterMismatch(
                    expected: initial.id,
                    found: encounterID
                )
            }
            if previousSequence == record.sequence {
                throw ReplayValidationError.duplicateSequence(record.sequence)
            }
            guard record.sequence >= expected else {
                throw ReplayValidationError.staleSequence(
                    expectedAtLeast: expected,
                    found: record.sequence
                )
            }
            guard record.sequence == expected else {
                throw ReplayValidationError.sequenceGap(
                    expected: expected,
                    found: record.sequence
                )
            }
            previousSequence = record.sequence
            expected += 1
        }

        return replay(initial: initial, events: ordered.map(RecordedEvent.init))
    }

    public static func replay(initial: EncounterState, records: [EventRecord]) -> EncounterState {
        replay(initial: initial, events: records.map(RecordedEvent.init))
    }
}

public struct BranchComparison: Equatable, Sendable {
    public let originalBranchID: UUID
    public let retryBranchID: UUID
    public let objectiveStatusChanges: [String: ObjectiveStatus]
    public let originalTurnCount: Int
    public let retryTurnCount: Int
}

public enum BranchComparator {
    public static func compare(original: EncounterState, retry: EncounterState) -> BranchComparison {
        var changes: [String: ObjectiveStatus] = [:]
        for objective in retry.objectives {
            let previous = original.objectives.first { $0.id == objective.id }?.status
            if previous != objective.status { changes[objective.id] = objective.status }
        }
        return .init(
            originalBranchID: original.activeBranchID,
            retryBranchID: retry.activeBranchID,
            objectiveStatusChanges: changes,
            originalTurnCount: original.conversation.turns.count,
            retryTurnCount: retry.conversation.turns.count
        )
    }
}
