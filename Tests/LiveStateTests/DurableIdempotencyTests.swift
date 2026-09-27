import XCTest
@testable import LiveState

private actor IntentKeyEvaluationService: EvaluationService {
    private(set) var keys: [UUID] = []

    func evaluate(
        turnID: UUID,
        text: String,
        context: EvaluationContext,
        idempotencyKey: UUID
    ) async throws -> AnswerEvaluation {
        keys.append(idempotencyKey)
        return .init(answeredQuestion: true, relevance: 1, specificity: 1)
    }
}

private actor IntentKeyCounterpartService: CounterpartService {
    private(set) var keys: [UUID] = []

    func respond(
        to action: PolicyAction,
        context: CounterpartContext,
        idempotencyKey: UUID
    ) async throws -> String {
        keys.append(idempotencyKey)
        return "Canonical intent identity"
    }
}

private actor IntentKeyCheckpointStore: CheckpointStore {
    func save(_ checkpoint: Checkpoint) async throws {}
}

private actor IntentKeyEventStore: EventStore {
    func save(_ record: EventRecord) async throws {}
}

private actor IntentRecordingJournal: RuntimeJournal {
    private var events: [EventRecord] = []
    private var pending: [UUID: DurableEffectIntent] = [:]
    private var results: [UUID: SimulationEvent] = [:]
    private(set) var created: [DurableEffectIntent] = []

    func commit(
        event: EventRecord,
        intents: [DurableEffectIntent],
        completing intentID: UUID?
    ) async throws {
        if !events.contains(where: { $0.id == event.id }) {
            events.append(event)
        }
        if let intentID {
            pending.removeValue(forKey: intentID)
            results.removeValue(forKey: intentID)
        }
        for intent in intents {
            if pending[intent.id] == nil {
                created.append(intent)
            }
            pending[intent.id] = intent
        }
    }

    func records(encounterID: UUID) async throws -> [EventRecord] {
        events.filter { $0.encounterID == encounterID }
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

final class DurableIdempotencyTests: XCTestCase {
    func testJournalIntentIDIsCanonicalModelIdempotencyKey() async throws {
        let evaluation = IntentKeyEvaluationService()
        let counterpart = IntentKeyCounterpartService()
        let journal = IntentRecordingJournal()
        let runner = EffectRunner(
            evaluation: evaluation,
            counterpart: counterpart,
            checkpoints: IntentKeyCheckpointStore(),
            events: IntentKeyEventStore()
        )
        let runtime = EncounterRuntime(
            state: EncounterState(lifecycle: .active),
            runner: runner,
            journal: journal
        )

        _ = try await runtime.send(.userSubmitted("Use the durable identity"))

        let intents = await journal.created
        guard let evaluationIntent = intents.first(where: {
            if case .evaluateAnswer = $0.payload { return true }
            return false
        }) else {
            return XCTFail("Expected durable evaluation intent")
        }
        guard let counterpartIntent = intents.first(where: {
            if case .requestCounterpartAction = $0.payload { return true }
            return false
        }) else {
            return XCTFail("Expected durable counterpart intent")
        }

        let evaluationKeys = await evaluation.keys
        let counterpartKeys = await counterpart.keys

        XCTAssertEqual(evaluationKeys, [evaluationIntent.id])
        XCTAssertEqual(counterpartKeys, [counterpartIntent.id])
    }

    func testExplicitIdempotencyKeyOverridesLegacyDeterministicFallback() async throws {
        let evaluation = IntentKeyEvaluationService()
        let counterpart = IntentKeyCounterpartService()
        let runner = EffectRunner(
            evaluation: evaluation,
            counterpart: counterpart,
            checkpoints: IntentKeyCheckpointStore(),
            events: IntentKeyEventStore()
        )
        let state = EncounterState(lifecycle: .active)
        let key = UUID()
        let turnID = UUID()

        _ = try await runner.run(
            .evaluateAnswer(turnID: turnID, text: "Direct durable call"),
            state: state,
            idempotencyKey: key
        )

        let keys = await evaluation.keys
        XCTAssertEqual(keys, [key])
    }
}
