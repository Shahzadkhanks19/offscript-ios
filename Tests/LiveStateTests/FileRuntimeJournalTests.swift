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
        XCTAssertEqual(try await reopened.records(encounterID: state.id), [record])
        XCTAssertEqual(
            try await reopened.pendingIntents(encounterID: state.id).map(\.id),
            [intent.id]
        )
        XCTAssertEqual(try await reopened.result(for: intent.id), result)
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
        XCTAssertEqual(
            try await reopened.records(encounterID: state.id),
            [firstRecord, resultRecord]
        )
        XCTAssertTrue(try await reopened.pendingIntents(encounterID: state.id).isEmpty)
        XCTAssertNil(try await reopened.result(for: intent.id))

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
        XCTAssertEqual(try await reopened.records(encounterID: state.id), [first])
    }
}
