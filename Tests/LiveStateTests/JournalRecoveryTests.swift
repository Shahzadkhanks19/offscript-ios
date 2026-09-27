import XCTest
@testable import LiveState

private struct RecoveryEvaluationService: EvaluationService {
    func evaluate(
        turnID: UUID,
        text: String,
        context: EvaluationContext,
        idempotencyKey: UUID
    ) async throws -> AnswerEvaluation {
        .init(answeredQuestion: true, relevance: 1, specificity: 1)
    }
}

private struct RecoveryCounterpartService: CounterpartService {
    func respond(
        to action: PolicyAction,
        context: CounterpartContext,
        idempotencyKey: UUID
    ) async throws -> String {
        "Recovered from journal"
    }
}

private struct RecoveryCheckpointStore: CheckpointStore {
    func save(_ checkpoint: Checkpoint) async throws {}
}

private struct RecoveryEventStore: EventStore {
    func save(_ record: EventRecord) async throws {}
}

private actor AuthoritativeRecoveryJournal: RuntimeJournal {
    private var committed: [EventRecord] = []
    private var pending: [UUID: DurableEffectIntent] = [:]
    private var results: [UUID: SimulationEvent] = [:]

    func commit(
        event: EventRecord,
        intents: [DurableEffectIntent],
        completing intentID: UUID?
    ) async throws {
        if !committed.contains(where: { $0.id == event.id }) {
            committed.append(event)
        }
        if let intentID {
            pending.removeValue(forKey: intentID)
            results.removeValue(forKey: intentID)
        }
        for intent in intents {
            pending[intent.id] = intent
        }
    }

    func records(encounterID: UUID) async throws -> [EventRecord] {
        committed.filter { $0.encounterID == encounterID }
            .sorted { $0.sequence < $1.sequence }
    }

    func pendingIntents(encounterID: UUID) async throws -> [DurableEffectIntent] {
        pending.values.filter { $0.encounterID == encounterID }
    }

    func markCompleted(intentID: UUID) async throws {
        pending.removeValue(forKey: intentID)
        results.removeValue(forKey: intentID)
    }

    func result(for intentID: UUID) async throws -> SimulationEvent? {
        results[intentID]
    }

    func saveResult(_ event: SimulationEvent, for intentID: UUID) async throws {
        guard let intent = pending[intentID] else {
            throw RuntimeJournalError.resultForUnknownIntent(intentID: intentID)
        }
        try DurableResultValidator.validate(event, for: intent)
        if let existing = results[intentID] {
            guard existing == event else {
                throw RuntimeJournalError.resultConflict(intentID: intentID)
            }
            return
        }
        results[intentID] = event
    }
}

final class JournalRecoveryTests: XCTestCase {
    func testRuntimeRecoversAuthoritativeStateDirectlyFromJournal() async throws {
        let initial = EncounterState(lifecycle: .active)
        let journal = AuthoritativeRecoveryJournal()
        let runner = EffectRunner(
            evaluation: RecoveryEvaluationService(),
            counterpart: RecoveryCounterpartService(),
            checkpoints: RecoveryCheckpointStore(),
            events: RecoveryEventStore()
        )
        let firstRuntime = EncounterRuntime(
            state: initial,
            runner: runner,
            journal: journal
        )

        let beforeRestart = try await firstRuntime.send(
            .userSubmitted("Journal owns recovery truth")
        )
        XCTAssertEqual(beforeRestart.sequence, 3)

        let restarted = try await EncounterRuntime.recovering(
            initial: initial,
            runner: runner,
            journal: journal
        )
        let recovered = await restarted.state

        XCTAssertEqual(recovered, beforeRestart)
        XCTAssertEqual(recovered.sequence, 3)
        XCTAssertEqual(
            recovered.conversation.turns.map(\.text),
            ["Journal owns recovery truth", "Recovered from journal"]
        )
        let legacyPending = await restarted.pendingEffects
        XCTAssertTrue(legacyPending.isEmpty)
    }
}
