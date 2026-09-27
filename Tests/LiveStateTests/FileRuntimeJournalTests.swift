import Foundation
import XCTest
@testable import LiveState

final class FileRuntimeJournalTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("offscript-journal-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private func makeEvaluationIntent(state: EncounterState, turnID: UUID) -> DurableEffectIntent {
        DurableEffectIntent(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            originatingSequence: 1,
            effectIndex: 0,
            payload: .evaluateAnswer(turnID: turnID, text: "Persist me"),
            state: state
        )
    }

    func testJournalPersistsEventsIntentsAndCachedResultsAcrossReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = EncounterState(lifecycle: .active)
        let turnID = UUID()
        let intent = makeEvaluationIntent(state: state, turnID: turnID)
        let record = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("Persist me")
        )
        let result = SimulationEvent.answerEvaluated(
            turnID: turnID,
            .init(answeredQuestion: true, relevance: 1, specificity: 1)
        )

        var journal: FileRuntimeJournal? = try FileRuntimeJournal(fileURL: url)
        try await journal!.commit(event: record, intents: [intent], completing: nil)
        try await journal!.saveResult(result, for: intent.id)
        journal = nil

        let reopened = try FileRuntimeJournal(fileURL: url)
        let records = try await reopened.records(encounterID: state.id)
        let pendingIDs = try await reopened.pendingIntents(encounterID: state.id).map(\.id)
        let cachedResult = try await reopened.result(for: intent.id)
        XCTAssertEqual(records, [record])
        XCTAssertEqual(pendingIDs, [intent.id])
        XCTAssertEqual(cachedResult, result)
    }

    func testCompletionPersistsAndRemovesCachedResultAcrossReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = EncounterState(lifecycle: .active)
        let turnID = UUID()
        let intent = makeEvaluationIntent(state: state, turnID: turnID)
        let firstRecord = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("Persist completion")
        )
        let result = SimulationEvent.answerEvaluated(
            turnID: turnID,
            .init(answeredQuestion: true, relevance: 1, specificity: 1)
        )
        let resultRecord = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 2,
            timestamp: Date(timeIntervalSince1970: 2),
            event: result
        )

        var journal: FileRuntimeJournal? = try FileRuntimeJournal(fileURL: url)
        try await journal!.commit(event: firstRecord, intents: [intent], completing: nil)
        try await journal!.saveResult(result, for: intent.id)
        try await journal!.commit(event: resultRecord, intents: [], completing: intent.id)
        journal = nil

        let reopened = try FileRuntimeJournal(fileURL: url)
        let records = try await reopened.records(encounterID: state.id)
        let pending = try await reopened.pendingIntents(encounterID: state.id)
        let cachedResult = try await reopened.result(for: intent.id)
        XCTAssertEqual(records, [firstRecord, resultRecord])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(cachedResult)

        do {
            try await reopened.saveResult(result, for: intent.id)
            XCTFail("Completed intent must not accept another result")
        } catch let error as RuntimeJournalError {
            XCTAssertEqual(error, .resultForUnknownIntent(intentID: intent.id))
        }
    }

    func testFailedConflictingCommitDoesNotMutatePersistentSnapshot() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = EncounterState(lifecycle: .active)
        let first = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("first")
        )
        let conflict = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("conflict")
        )

        let journal = try FileRuntimeJournal(fileURL: url)
        try await journal.commit(event: first, intents: [], completing: nil)

        do {
            try await journal.commit(event: conflict, intents: [], completing: nil)
            XCTFail("Expected sequence conflict")
        } catch let error as RuntimeJournalError {
            XCTAssertEqual(
                error,
                .sequenceConflict(encounterID: state.id, sequence: 1)
            )
        }

        let reopened = try FileRuntimeJournal(fileURL: url)
        let records = try await reopened.records(encounterID: state.id)
        XCTAssertEqual(records, [first])
    }

    func testExactTransactionReplayIsIdempotentAcrossReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = EncounterState(lifecycle: .active)
        let intent = makeEvaluationIntent(state: state, turnID: UUID())
        let record = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("same transaction")
        )

        var journal: FileRuntimeJournal? = try FileRuntimeJournal(fileURL: url)
        try await journal!.commit(event: record, intents: [intent], completing: nil)
        journal = nil

        let reopened = try FileRuntimeJournal(fileURL: url)
        try await reopened.commit(event: record, intents: [intent], completing: nil)

        let records = try await reopened.records(encounterID: state.id)
        let pending = try await reopened.pendingIntents(encounterID: state.id)
        XCTAssertEqual(records, [record])
        XCTAssertEqual(pending.map(\.id), [intent.id])
    }

    func testReplayRejectsDifferentChildIntentsForSameEvent() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = EncounterState(lifecycle: .active)
        let firstIntent = makeEvaluationIntent(state: state, turnID: UUID())
        let differentIntent = makeEvaluationIntent(state: state, turnID: UUID())
        let record = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("transaction identity")
        )

        let journal = try FileRuntimeJournal(fileURL: url)
        try await journal.commit(event: record, intents: [firstIntent], completing: nil)

        do {
            try await journal.commit(event: record, intents: [differentIntent], completing: nil)
            XCTFail("Same event cannot be replayed with different child intents")
        } catch let error as RuntimeJournalError {
            XCTAssertEqual(error, .transactionConflict(eventID: record.id))
        }
    }

    func testReplayRejectsDifferentParentCompletionForSameEvent() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = EncounterState(lifecycle: .active)
        let record = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("completion identity")
        )

        let journal = try FileRuntimeJournal(fileURL: url)
        try await journal.commit(event: record, intents: [], completing: nil)

        do {
            try await journal.commit(event: record, intents: [], completing: UUID())
            XCTFail("Same event cannot be replayed with a different parent completion")
        } catch let error as RuntimeJournalError {
            XCTAssertEqual(error, .transactionConflict(eventID: record.id))
        }
    }


    func testVersionOneSnapshotMigratesWithoutLosingDurableState() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = EncounterState(lifecycle: .active)
        let intent = makeEvaluationIntent(state: state, turnID: UUID())
        let record = EventRecord(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("legacy journal")
        )
        let result = SimulationEvent.answerEvaluated(
            intentPayloadTurnID(intent),
            AnswerEvaluation(answeredQuestion: true, relevance: 1, specificity: 1)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyObject: [String: Any] = [
            "schemaVersion": 1,
            "events": try JSONSerialization.jsonObject(with: encoder.encode([record])),
            "intents": try JSONSerialization.jsonObject(with: encoder.encode([intent.id: intent])),
            "results": try JSONSerialization.jsonObject(with: encoder.encode([intent.id: result])),
            "completedIntentIDs": []
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)

        let journal = try FileRuntimeJournal(fileURL: url)
        let records = try await journal.records(encounterID: state.id)
        let pending = try await journal.pendingIntents(encounterID: state.id)
        let cached = try await journal.result(for: intent.id)

        XCTAssertEqual(records, [record])
        XCTAssertEqual(pending.map(\.id), [intent.id])
        XCTAssertEqual(cached, result)

        // A mutation rewrites the migrated in-memory snapshot as schema v2.
        try await journal.markCompleted(intentID: intent.id)
        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
        XCTAssertEqual(persisted?["schemaVersion"] as? Int, 2)
    }

    func testFutureJournalSchemaIsRejected() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 999,
            "events": [],
            "transactions": [:],
            "intents": [:],
            "results": [:],
            "completedIntentIDs": []
        ])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)

        XCTAssertThrowsError(try FileRuntimeJournal(fileURL: url)) { error in
            XCTAssertEqual(error as? FileRuntimeJournal.StorageError, .unsupportedSchema(999))
        }
    }

}
