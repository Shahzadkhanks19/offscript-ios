import XCTest
@testable import LiveState

private struct FixedEvaluationService: EvaluationService {
    let result: AnswerEvaluation

    func evaluate(
        turnID: UUID,
        text: String,
        context: EvaluationContext
    ) async throws -> AnswerEvaluation {
        result
    }
}

private struct FixedCounterpartService: CounterpartService {
    let response: String

    func respond(
        to action: PolicyAction,
        context: CounterpartContext
    ) async throws -> String {
        response
    }
}

private actor MemoryCheckpointStore: CheckpointStore {
    private(set) var saved: [Checkpoint] = []

    func save(_ checkpoint: Checkpoint) async throws {
        saved.append(checkpoint)
    }
}

private actor MemoryEventStore: EventStore {
    private(set) var saved: [EventRecord] = []

    func save(_ record: EventRecord) async throws {
        saved.append(record)
    }
}


private enum TestStoreError: Error {
    case persistenceFailed
}

private actor FailingEventStore: EventStore {
    private(set) var attempts = 0

    func save(_ record: EventRecord) async throws {
        attempts += 1
        throw TestStoreError.persistenceFailed
    }
}


private actor FailOnceEvaluationService: EvaluationService {
    private var shouldFail = true
    private let result: AnswerEvaluation

    init(result: AnswerEvaluation) {
        self.result = result
    }

    func evaluate(
        turnID: UUID,
        text: String,
        context: EvaluationContext
    ) async throws -> AnswerEvaluation {
        if shouldFail {
            shouldFail = false
            throw TestStoreError.persistenceFailed
        }
        return result
    }
}

final class EncounterRuntimeTests: XCTestCase {
    func testRuntimeCompletesUserEvaluationPolicyAndCounterpartLoop() async throws {
        let evaluation = AnswerEvaluation(
            answeredQuestion: true,
            relevance: 0.95,
            specificity: 0.9,
            objectiveEvaluations: [
                .init(
                    objectiveID: "architectureReasoning",
                    status: .satisfied,
                    reason: "Explains the architecture decision.",
                    confidence: 0.95
                )
            ]
        )
        let eventStore = MemoryEventStore()
        let checkpointStore = MemoryCheckpointStore()
        let runner = EffectRunner(
            evaluation: FixedEvaluationService(result: evaluation),
            counterpart: FixedCounterpartService(response: "What tradeoff did that introduce?"),
            checkpoints: checkpointStore,
            events: eventStore
        )
        let runtime = EncounterRuntime(
            state: EncounterState(lifecycle: .active),
            runner: runner
        )

        let final = try await runtime.send(
            .userSubmitted("We chose Next.js because SSR improved discoverability.")
        )

        XCTAssertEqual(final.user.totalTurns, 1)
        XCTAssertEqual(final.conversation.turns.count, 2)
        XCTAssertEqual(final.conversation.turns.first?.speaker, .user)
        XCTAssertEqual(final.conversation.turns.last?.speaker, .counterpart)
        XCTAssertEqual(final.conversation.turns.last?.text, "What tradeoff did that introduce?")
        XCTAssertEqual(
            final.objectives.first(where: { $0.id == "architectureReasoning" })?.status,
            .satisfied
        )
        XCTAssertEqual(final.conversation.turnState, .idle)

        let records = await eventStore.saved
        XCTAssertEqual(records.map(\.kind), [
            "userSubmitted",
            "answerEvaluated",
            "counterpartResponded"
        ])
        XCTAssertEqual(records.map(\.sequence), [1, 2, 3])
    }

    func testCounterpartProjectionExcludesPrivateUserKnowledge() {
        var state = EncounterState(lifecycle: .active)
        state.scenario.knowledge = .init(
            counterpartVisible: [
                .init(id: "role", value: "Senior React Developer")
            ],
            privateUserContext: [
                .init(id: "practice-focus", value: "Needs system design practice")
            ]
        )

        let context = CounterpartContext(state: state)

        XCTAssertEqual(context.visibleKnowledge.map(\.id), ["role"])
        XCTAssertFalse(context.visibleKnowledge.contains { $0.id == "practice-focus" })
    }

    func testEvaluationProjectionIncludesExplicitPrivateCoachingContext() {
        var state = EncounterState(lifecycle: .active)
        state.scenario.knowledge = .init(
            counterpartVisible: [.init(id: "role", value: "Senior React Developer")],
            privateUserContext: [.init(id: "focus", value: "Practice concise answers")]
        )

        let context = EvaluationContext(state: state)

        XCTAssertEqual(context.visibleKnowledge.map(\.id), ["role"])
        XCTAssertEqual(context.privateUserContext.map(\.id), ["focus"])
    }
    func testRuntimeDoesNotCommitStateWhenEventPersistenceFails() async {
        let eventStore = FailingEventStore()
        let checkpointStore = MemoryCheckpointStore()
        let runner = EffectRunner(
            evaluation: FixedEvaluationService(result: .init(answeredQuestion: true, relevance: 1, specificity: 1)),
            counterpart: FixedCounterpartService(response: "Should never run"),
            checkpoints: checkpointStore,
            events: eventStore
        )
        let initial = EncounterState(lifecycle: .active)
        let runtime = EncounterRuntime(state: initial, runner: runner)

        do {
            _ = try await runtime.send(.userSubmitted("This must not commit."))
            XCTFail("Expected persistence failure")
        } catch {
            // Expected.
        }

        let afterFailure = await runtime.state
        XCTAssertEqual(afterFailure, initial)
        XCTAssertEqual(afterFailure.sequence, 0)
        XCTAssertTrue(afterFailure.conversation.turns.isEmpty)
        let persistenceAttempts = await eventStore.attempts
        let savedCheckpoints = await checkpointStore.saved
        XCTAssertEqual(persistenceAttempts, 1)
        XCTAssertTrue(savedCheckpoints.isEmpty)
    }

    func testRuntimeRetainsAndResumesFailedPostCommitEffect() async throws {
        let evaluation = AnswerEvaluation(
            answeredQuestion: true,
            relevance: 1,
            specificity: 1
        )
        let evaluationService = FailOnceEvaluationService(result: evaluation)
        let eventStore = MemoryEventStore()
        let checkpointStore = MemoryCheckpointStore()
        let runner = EffectRunner(
            evaluation: evaluationService,
            counterpart: FixedCounterpartService(response: "Recovered follow-up"),
            checkpoints: checkpointStore,
            events: eventStore
        )
        let runtime = EncounterRuntime(
            state: EncounterState(lifecycle: .active),
            runner: runner
        )

        do {
            _ = try await runtime.send(.userSubmitted("Persist me before evaluation."))
            XCTFail("Expected first evaluation attempt to fail")
        } catch {
            // The userSubmitted event is already durable at this point.
        }

        let committed = await runtime.state
        let pendingAfterFailure = await runtime.pendingEffects
        XCTAssertEqual(committed.sequence, 1)
        XCTAssertEqual(committed.conversation.turns.count, 1)
        XCTAssertEqual(pendingAfterFailure.count, 1)

        let recovered = try await runtime.resumePendingEffects()
        XCTAssertTrue((await runtime.pendingEffects).isEmpty)
        XCTAssertEqual(recovered.sequence, 3)
        XCTAssertEqual(recovered.conversation.turns.count, 2)

        let records = await eventStore.saved
        XCTAssertEqual(records.map(\.kind), [
            "userSubmitted",
            "answerEvaluated",
            "counterpartResponded"
        ])
        XCTAssertEqual(records.map(\.sequence), [1, 2, 3])
    }

}
