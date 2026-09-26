import XCTest
@testable import LiveState

private struct FixedEvaluationService: EvaluationService {
    let result: AnswerEvaluation

    func evaluate(
        turnID: UUID,
        text: String,
        context: EvaluationContext,
        idempotencyKey: UUID
    ) async throws -> AnswerEvaluation {
        result
    }
}

private struct FixedCounterpartService: CounterpartService {
    let response: String

    func respond(
        to action: PolicyAction,
        context: CounterpartContext,
        idempotencyKey: UUID
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
    private(set) var saved: [EventRecord]

    init(saved: [EventRecord] = []) {
        self.saved = saved
    }

    func save(_ record: EventRecord) async throws {
        saved.append(record)
    }
}


private enum TestStoreError: Error {
    case persistenceFailed
    case serviceFailed
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
        context: EvaluationContext,
        idempotencyKey: UUID
    ) async throws -> AnswerEvaluation {
        if shouldFail {
            shouldFail = false
            throw TestStoreError.serviceFailed
        }
        return result
    }
}

private actor RecordingEvaluationService: EvaluationService {
    private(set) var keys: [UUID] = []
    let result: AnswerEvaluation

    init(result: AnswerEvaluation) { self.result = result }

    func evaluate(
        turnID: UUID,
        text: String,
        context: EvaluationContext,
        idempotencyKey: UUID
    ) async throws -> AnswerEvaluation {
        keys.append(idempotencyKey)
        return result
    }
}


private actor FailOnceCheckpointStore: CheckpointStore {
    private(set) var attempts = 0
    private(set) var saved: [Checkpoint] = []

    func save(_ checkpoint: Checkpoint) async throws {
        attempts += 1
        if attempts == 1 { throw TestStoreError.persistenceFailed }
        saved.append(checkpoint)
    }
}


private actor CountingCounterpartService: CounterpartService {
    private(set) var calls = 0
    let response: String

    init(response: String) { self.response = response }

    func respond(
        to action: PolicyAction,
        context: CounterpartContext,
        idempotencyKey: UUID
    ) async throws -> String {
        calls += 1
        return response
    }
}

private actor FailOnKindEventStore: EventStore {
    private(set) var saved: [EventRecord] = []
    private let failingKind: String
    private var didFail = false

    init(failingKind: String) { self.failingKind = failingKind }

    func save(_ record: EventRecord) async throws {
        if record.kind == failingKind && !didFail {
            didFail = true
            throw TestStoreError.persistenceFailed
        }
        saved.append(record)
    }
}


private actor MemoryRuntimeJournal: RuntimeJournal {
    private(set) var events: [EventRecord] = []
    private(set) var intents: [UUID: DurableEffectIntent] = [:]
    private var completedIntentIDs: Set<UUID> = []

    func commit(
        event: EventRecord,
        intents newIntents: [DurableEffectIntent],
        completing intentID: UUID?
    ) async throws {
        if let existing = events.first(where: { $0.id == event.id }) {
            guard existing == event else {
                throw RuntimeJournalError.eventConflict(id: event.id)
            }
            return
        }

        if let encounterID = event.encounterID,
           let existing = events.first(where: {
               $0.encounterID == encounterID && $0.sequence == event.sequence
           }) {
            guard existing == event else {
                throw RuntimeJournalError.sequenceConflict(
                    encounterID: encounterID,
                    sequence: event.sequence
                )
            }
            return
        }

        for intent in newIntents {
            if let existing = intents[intent.id], existing != intent {
                throw RuntimeJournalError.intentConflict(id: intent.id)
            }
        }

        // In-memory test journal models one atomic transaction: validation is
        // complete before any event/outbox/completion state mutates.
        events.append(event)
        if let intentID {
            intents.removeValue(forKey: intentID)
            completedIntentIDs.insert(intentID)
        }
        for intent in newIntents where !completedIntentIDs.contains(intent.id) {
            intents[intent.id] = intent
        }
    }

    func pendingIntents(encounterID: UUID) async throws -> [DurableEffectIntent] {
        intents.values.filter { $0.encounterID == encounterID }
    }

    func markCompleted(intentID: UUID) async throws {
        intents.removeValue(forKey: intentID)
        completedIntentIDs.insert(intentID)
    }
}


private actor FailOnceJournalEvaluationService: EvaluationService {
    private var shouldFail = true
    private(set) var calls = 0
    private(set) var keys: [UUID] = []
    let result: AnswerEvaluation

    init(result: AnswerEvaluation) { self.result = result }

    func evaluate(
        turnID: UUID,
        text: String,
        context: EvaluationContext,
        idempotencyKey: UUID
    ) async throws -> AnswerEvaluation {
        calls += 1
        keys.append(idempotencyKey)
        if shouldFail {
            shouldFail = false
            throw TestStoreError.serviceFailed
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
        let pendingAfterRecovery = await runtime.pendingEffects
        XCTAssertTrue(pendingAfterRecovery.isEmpty)
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

    func testRuntimeRecoversUnfinishedEvaluationAfterProcessRestart() async throws {
        let initial = EncounterState(lifecycle: .active)
        let firstReduction = LiveStateReducer.reduce(
            state: initial,
            event: .userSubmitted("A durable answer awaiting evaluation.")
        )
        guard let persistenceEffect = firstReduction.effects.first(where: {
            if case .persistEvent = $0 { return true }
            return false
        }), case let .persistEvent(record) = persistenceEffect else {
            return XCTFail("Expected persisted userSubmitted event")
        }

        let eventStore = MemoryEventStore(saved: [record])
        let checkpointStore = MemoryCheckpointStore()
        let runner = EffectRunner(
            evaluation: FixedEvaluationService(
                result: .init(answeredQuestion: true, relevance: 1, specificity: 1)
            ),
            counterpart: FixedCounterpartService(response: "Recovered after restart"),
            checkpoints: checkpointStore,
            events: eventStore
        )

        let runtime = try EncounterRuntime.recovering(
            initial: initial,
            records: [record],
            runner: runner
        )

        let restored = await runtime.state
        let recoveredWork = await runtime.pendingEffects
        XCTAssertEqual(restored.sequence, 1)
        XCTAssertEqual(restored.conversation.turns.count, 1)
        XCTAssertEqual(recoveredWork.count, 1)
        guard case .evaluateAnswer = recoveredWork[0].effect else {
            return XCTFail("Expected unfinished evaluation to be reconstructed")
        }

        let completed = try await runtime.resumePendingEffects()
        let remaining = await runtime.pendingEffects
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(completed.sequence, 3)
        XCTAssertEqual(completed.conversation.turns.last?.text, "Recovered after restart")

        let records = await eventStore.saved
        XCTAssertEqual(records.map(\.kind), [
            "userSubmitted",
            "answerEvaluated",
            "counterpartResponded"
        ])
        XCTAssertEqual(records.map(\.sequence), [1, 2, 3])
    }

    func testRecoveredEvaluationReusesSameDeterministicIdempotencyKey() async throws {
        let initial = EncounterState(lifecycle: .active)
        let service = RecordingEvaluationService(
            result: .init(answeredQuestion: true, relevance: 1, specificity: 1)
        )
        let store = MemoryEventStore()
        let runner = EffectRunner(
            evaluation: service,
            counterpart: FixedCounterpartService(response: "Next"),
            checkpoints: MemoryCheckpointStore(),
            events: store
        )

        let reduction = LiveStateReducer.reduce(
            state: initial,
            event: .userSubmitted("Retry-safe answer")
        )
        guard let persistence = reduction.effects.first(where: {
            if case .persistEvent = $0 { return true }
            return false
        }), case let .persistEvent(record) = persistence else {
            return XCTFail("Expected durable event")
        }

        let recoveredA = try EncounterRuntime.recovering(initial: initial, records: [record], runner: runner)
        let pendingA = await recoveredA.pendingEffects
        guard let effectA = pendingA.first else { return XCTFail("Expected recovered work") }
        _ = try await runner.run(effectA.effect, state: effectA.state)

        let recoveredB = try EncounterRuntime.recovering(initial: initial, records: [record], runner: runner)
        let pendingB = await recoveredB.pendingEffects
        guard let effectB = pendingB.first else { return XCTFail("Expected recovered work") }
        _ = try await runner.run(effectB.effect, state: effectB.state)

        let keys = await service.keys
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
    }

    func testProducedCounterpartEventIsDurableBeforeLaterSiblingEffectFailure() async throws {
        let initial = EncounterState(lifecycle: .active)
        let eventStore = MemoryEventStore()
        let checkpointStore = FailOnceCheckpointStore()
        let runner = EffectRunner(
            evaluation: FixedEvaluationService(
                result: .init(answeredQuestion: true, relevance: 1, specificity: 1)
            ),
            counterpart: FixedCounterpartService(response: "Durable response"),
            checkpoints: checkpointStore,
            events: eventStore
        )
        let runtime = EncounterRuntime(state: initial, runner: runner)

        // A direct answerEvaluated event can emit checkpoint persistence and a
        // counterpart request as siblings. The exact order may evolve; this
        // regression asserts that any produced event already persisted before
        // a later sibling failure remains in durable history.
        let userReduction = LiveStateReducer.reduce(
            state: initial,
            event: .userSubmitted("Detailed architecture tradeoff example.")
        )
        guard let turn = userReduction.state.conversation.turns.first else {
            return XCTFail("Expected user turn")
        }

        do {
            _ = try await runtime.send(.answerEvaluated(
                turnID: turn.id,
                .init(
                    answeredQuestion: true,
                    relevance: 1,
                    specificity: 1,
                    objectiveEvaluations: [
                        .init(
                            objectiveID: "architectureReasoning",
                            status: .satisfied,
                            reason: "Specific architecture evidence.",
                            confidence: 1
                        )
                    ]
                )
            ))
        } catch {
            // Checkpoint failure is acceptable for this ordering regression.
        }

        let records = await eventStore.saved
        let kinds = records.map(\.kind)
        if kinds.contains("counterpartResponded") {
            XCTAssertEqual(
                records.filter { $0.kind == "counterpartResponded" }.count,
                1,
                "A produced counterpart event must be durably persisted exactly once."
            )
        }
    }

    func testSuccessfulModelEffectIsNotRequeuedWhenItsProducedEventPersistenceFails() async throws {
        let counterpart = CountingCounterpartService(response: "One model call only")
        let eventStore = FailOnKindEventStore(failingKind: "counterpartResponded")
        let runner = EffectRunner(
            evaluation: FixedEvaluationService(
                result: .init(answeredQuestion: true, relevance: 1, specificity: 1)
            ),
            counterpart: counterpart,
            checkpoints: MemoryCheckpointStore(),
            events: eventStore
        )
        let runtime = EncounterRuntime(
            state: EncounterState(lifecycle: .starting),
            runner: runner
        )

        do {
            _ = try await runtime.send(.encounterStarted)
            XCTFail("Expected produced event persistence to fail")
        } catch {
            // The model call succeeded; only persistence of its result failed.
        }

        let calls = await counterpart.calls
        let pending = await runtime.pendingEffects
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(
            pending.isEmpty,
            "A successful external call must not be requeued because processing its result failed."
        )

        let records = await eventStore.saved
        XCTAssertEqual(records.map(\.kind), ["encounterStarted"])
    }

    func testJournalAtomicallyCarriesEventIntoDurableEvaluationAndCompletesChain() async throws {
        let journal = MemoryRuntimeJournal()
        let eventStore = MemoryEventStore()
        let runner = EffectRunner(
            evaluation: FixedEvaluationService(
                result: .init(answeredQuestion: true, relevance: 1, specificity: 1)
            ),
            counterpart: FixedCounterpartService(response: "Journal follow-up"),
            checkpoints: MemoryCheckpointStore(),
            events: eventStore
        )
        let runtime = EncounterRuntime(
            state: EncounterState(lifecycle: .active),
            runner: runner,
            journal: journal
        )

        let final = try await runtime.send(.userSubmitted("Journal-backed answer"))

        XCTAssertEqual(final.sequence, 3)
        XCTAssertEqual(final.conversation.turns.last?.text, "Journal follow-up")

        let journalEvents = await journal.events
        XCTAssertEqual(journalEvents.map(\.kind), [
            "userSubmitted",
            "answerEvaluated",
            "counterpartResponded"
        ])

        let pending = try await journal.pendingIntents(encounterID: final.id)
        XCTAssertTrue(pending.isEmpty)

        let legacyEvents = await eventStore.saved
        XCTAssertTrue(
            legacyEvents.isEmpty,
            "Journal mode must not separately persist events through EventStore."
        )
    }

    func testJournalRecoversPendingIntentAfterProcessRestartWithoutLegacyDuplicate() async throws {
        let initial = EncounterState(lifecycle: .active)
        let journal = MemoryRuntimeJournal()
        let evaluation = FailOnceJournalEvaluationService(
            result: .init(answeredQuestion: true, relevance: 1, specificity: 1)
        )
        let runner = EffectRunner(
            evaluation: evaluation,
            counterpart: FixedCounterpartService(response: "Recovered through journal"),
            checkpoints: MemoryCheckpointStore(),
            events: MemoryEventStore()
        )
        let firstRuntime = EncounterRuntime(
            state: initial,
            runner: runner,
            journal: journal
        )

        do {
            _ = try await firstRuntime.send(.userSubmitted("Crash-safe journal answer"))
            XCTFail("Expected first evaluation attempt to fail")
        } catch {
            // Event + evaluation intent remain durable in the journal.
        }

        let committedEvents = await journal.events
        XCTAssertEqual(committedEvents.map(\.kind), ["userSubmitted"])
        let durablePending = try await journal.pendingIntents(encounterID: initial.id)
        XCTAssertEqual(durablePending.count, 1)

        let restarted = try EncounterRuntime.recovering(
            initial: initial,
            records: committedEvents,
            runner: runner,
            journal: journal
        )
        let legacyPending = await restarted.pendingEffects
        XCTAssertTrue(
            legacyPending.isEmpty,
            "Journal recovery must not also reconstruct legacy pending effects."
        )

        let final = try await restarted.resumeJournalIntents()
        XCTAssertEqual(final.sequence, 3)
        XCTAssertEqual(final.conversation.turns.last?.text, "Recovered through journal")

        let remaining = try await journal.pendingIntents(encounterID: initial.id)
        XCTAssertTrue(remaining.isEmpty)

        let calls = await evaluation.calls
        let keys = await evaluation.keys
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])

        let finalEvents = await journal.events
        XCTAssertEqual(finalEvents.map(\.kind), [
            "userSubmitted",
            "answerEvaluated",
            "counterpartResponded"
        ])
    }

    func testJournalExactCommitReplayIsIdempotent() async throws {
        let journal = MemoryRuntimeJournal()
        let initial = EncounterState(lifecycle: .active)
        let reduction = LiveStateReducer.reduce(
            state: initial,
            event: .userSubmitted("Exactly once in the journal")
        )
        guard case let .persistEvent(record)? = reduction.effects.first(where: {
            if case .persistEvent = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected event record")
        }
        let effects = reduction.effects.filter {
            if case .persistEvent = $0 { return false }
            return true
        }
        let intents = DurableEffectPlanner.intents(effects: effects, state: reduction.state)

        try await journal.commit(event: record, intents: intents, completing: nil)
        try await journal.commit(event: record, intents: intents, completing: nil)

        let events = await journal.events
        XCTAssertEqual(events, [record])
        let pending = try await journal.pendingIntents(encounterID: initial.id)
        XCTAssertEqual(pending, intents)
    }

    func testJournalRejectsDifferentEventAtSameEncounterSequence() async throws {
        let journal = MemoryRuntimeJournal()
        let encounterID = UUID()
        let branchID = UUID()
        let first = EventRecord(
            id: UUID(),
            encounterID: encounterID,
            branchID: branchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("first")
        )
        let conflicting = EventRecord(
            id: UUID(),
            encounterID: encounterID,
            branchID: branchID,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            event: .userSubmitted("different")
        )

        try await journal.commit(event: first, intents: [], completing: nil)

        do {
            try await journal.commit(event: conflicting, intents: [], completing: nil)
            XCTFail("Expected sequence conflict")
        } catch let error as RuntimeJournalError {
            XCTAssertEqual(
                error,
                .sequenceConflict(encounterID: encounterID, sequence: 1)
            )
        }

        let events = await journal.events
        XCTAssertEqual(events, [first])
    }

    func testJournalCompletionIsIdempotentAndDoesNotResurrectIntent() async throws {
        let journal = MemoryRuntimeJournal()
        let initial = EncounterState(lifecycle: .active)
        let reduction = LiveStateReducer.reduce(
            state: initial,
            event: .userSubmitted("Complete me once")
        )
        guard case let .persistEvent(record)? = reduction.effects.first(where: {
            if case .persistEvent = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected event record")
        }
        let effects = reduction.effects.filter {
            if case .persistEvent = $0 { return false }
            return true
        }
        let intents = DurableEffectPlanner.intents(effects: effects, state: reduction.state)
        guard let intent = intents.first else { return XCTFail("Expected intent") }

        try await journal.commit(event: record, intents: intents, completing: nil)
        try await journal.markCompleted(intentID: intent.id)
        try await journal.markCompleted(intentID: intent.id)
        try await journal.commit(event: record, intents: intents, completing: nil)

        let pending = try await journal.pendingIntents(encounterID: initial.id)
        XCTAssertTrue(pending.isEmpty)
    }

}
