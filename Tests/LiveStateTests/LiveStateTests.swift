import XCTest
@testable import LiveState

final class LiveStateTests: XCTestCase {
    func testStartActivatesEncounterAndRequestsOpeningQuestion() {
        let result = LiveStateReducer.reduce(state: .init(), event: .encounterStarted)
        XCTAssertEqual(result.state.lifecycle, .active)
        XCTAssertEqual(result.state.conversation.turnState, .counterpartThinking)
        XCTAssertTrue(result.effects.contains(.requestCounterpartAction(.askOpeningQuestion)))
        XCTAssertEqual(result.state.sequence, 1)
    }

    func testUserSubmissionCreatesTurnAndEvaluationEffect() {
        let result = LiveStateReducer.reduce(state: .init(lifecycle: .active), event: .userSubmitted("I chose Next.js for SSR."))
        XCTAssertEqual(result.state.conversation.turns.count, 1)
        XCTAssertEqual(result.state.user.totalTurns, 1)
        XCTAssertGreaterThan(result.state.user.averageTurnCharacterCount, 0)
        XCTAssertTrue(result.effects.contains { if case .evaluateAnswer = $0 { true } else { false } })
    }

    func testObjectiveEvaluationRequiresEvidence() {
        var state = EncounterState(lifecycle: .active)
        let submitted = LiveStateReducer.reduce(state: state, event: .userSubmitted("SSR helped SEO, but increased server complexity."))
        state = submitted.state
        guard case let .evaluateAnswer(turnID, _) = submitted.effects.first(where: { if case .evaluateAnswer = $0 { true } else { false } }) else {
            return XCTFail("Expected evaluation effect")
        }
        let evaluation = AnswerEvaluation(
            answeredQuestion: true,
            relevance: 0.9,
            specificity: 0.8,
            objectiveEvaluations: [
                .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explains SSR motivation.", confidence: 0.94),
                .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Names server complexity tradeoff.", confidence: 0.91)
            ]
        )
        let result = LiveStateReducer.reduce(state: state, event: .answerEvaluated(turnID: turnID, evaluation))
        let tradeoff = result.state.objectives.first { $0.id == "tradeoffAwareness" }
        XCTAssertEqual(tradeoff?.status, .satisfied)
        XCTAssertEqual(tradeoff?.evidence.first?.turnID, turnID)
        XCTAssertFalse(tradeoff?.evidence.first?.reason.isEmpty ?? true)
    }

    func testMissingTradeoffIsChallenged() {
        var state = EncounterState(lifecycle: .active)
        let submitted = LiveStateReducer.reduce(state: state, event: .userSubmitted("Next.js improved discoverability."))
        state = submitted.state
        guard case let .evaluateAnswer(turnID, _) = submitted.effects.first(where: { if case .evaluateAnswer = $0 { true } else { false } }) else {
            return XCTFail("Expected evaluation effect")
        }
        let evaluation = AnswerEvaluation(
            answeredQuestion: true, relevance: 0.9, specificity: 0.8,
            objectiveEvaluations: [.init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explains motivation.", confidence: 0.9)]
        )
        let result = LiveStateReducer.reduce(state: state, event: .answerEvaluated(turnID: turnID, evaluation))
        XCTAssertTrue(result.effects.contains(.requestCounterpartAction(.challengeTradeoff)))
    }

    func testLowSpecificityRequestsExampleBeforeTradeoffChallenge() {
        let state = EncounterState(lifecycle: .active)
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.8, specificity: 0.2)
        XCTAssertEqual(PolicyEngine.nextAction(for: state, evaluation: evaluation), .askForSpecificExample)
    }

    func testPressureIsClamped() {
        var state = EncounterState(lifecycle: .active)
        state = LiveStateReducer.reduce(state: state, event: .pressureAdjusted(0.8)).state
        state = LiveStateReducer.reduce(state: state, event: .pressureAdjusted(0.8)).state
        XCTAssertEqual(state.pressure.adaptiveModifier, 1)
        XCTAssertEqual(state.pressure.effective, 1)
    }

    func testPauseResumeLifecycle() {
        var state = EncounterState(lifecycle: .active)
        state = LiveStateReducer.reduce(state: state, event: .encounterPaused).state
        XCTAssertEqual(state.lifecycle, .paused)
        XCTAssertEqual(state.conversation.turnState, .paused)
        state = LiveStateReducer.reduce(state: state, event: .encounterResumed).state
        XCTAssertEqual(state.lifecycle, .active)
        XCTAssertEqual(state.conversation.turnState, .idle)
    }

    func testRestorePreservesHistoryAndCreatesNewBranch() {
        var state = EncounterState(lifecycle: .active)
        state.conversation.turns.append(.init(speaker: .counterpart, text: "Why didn't you use Redux?"))
        let checkpoint = Branching.checkpoint(state)
        let originalBranch = state.activeBranchID
        let restored = Branching.restore(checkpoint)
        XCTAssertEqual(restored.conversation.turns, state.conversation.turns)
        XCTAssertNotEqual(restored.activeBranchID, originalBranch)
        XCTAssertEqual(checkpoint.parentBranchID, originalBranch)
    }

    func testEveryReductionAdvancesSequenceAndEmitsEventRecord() {
        let result = LiveStateReducer.reduce(state: .init(), event: .encounterStarted)
        XCTAssertEqual(result.state.sequence, 1)
        XCTAssertTrue(result.effects.contains { if case .persistEvent = $0 { true } else { false } })
    }
    func testStrongAnswerChangesCounterpartSimulationState() {
        var state = EncounterState(lifecycle: .active)
        let initialSkepticism = state.counterpart.skepticism
        let submitted = LiveStateReducer.reduce(state: state, event: .userSubmitted("We used SSR for discoverability and accepted extra server complexity."))
        state = submitted.state
        guard case let .evaluateAnswer(turnID, _) = submitted.effects.first(where: { if case .evaluateAnswer = $0 { true } else { false } }) else { return XCTFail() }
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.95, specificity: 0.9)
        let result = LiveStateReducer.reduce(state: state, event: .answerEvaluated(turnID: turnID, evaluation))
        XCTAssertLessThan(result.state.counterpart.skepticism, initialSkepticism)
        XCTAssertGreaterThan(result.state.counterpart.engagement, 0.65)
    }

    func testMomentEngineMarksSpecificMultiObjectiveAnswerStrong() {
        let turnID = UUID()
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.95, specificity: 0.9, objectiveEvaluations: [
            .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Clear reason", confidence: 0.9),
            .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Clear tradeoff", confidence: 0.9)
        ])
        XCTAssertEqual(MomentEngine.detect(turnID: turnID, evaluation: evaluation)?.kind, .strong)
    }

    func testSurpriseTargetsUnresolvedObjectiveAfterEnoughTurns() {
        var state = EncounterState(lifecycle: .active)
        state.pressure.base = 0.7
        state.user.totalTurns = 2
        let surprise = SurpriseEngine.next(for: state)
        XCTAssertNotNil(surprise)
        XCTAssertEqual(surprise?.targetObjectiveID, "architectureReasoning")
    }

    func testReplayProducesEquivalentCoreState() {
        let initial = EncounterState()
        let events = [
            RecordedEvent(sequence: 1, event: .encounterStarted),
            RecordedEvent(sequence: 2, event: .userSubmitted("A concrete answer"))
        ]
        let replayed = ReplayEngine.replay(initial: initial, events: events)
        var manual = LiveStateReducer.reduce(state: initial, event: .encounterStarted).state
        manual = LiveStateReducer.reduce(state: manual, event: .userSubmitted("A concrete answer")).state
        XCTAssertEqual(replayed.lifecycle, manual.lifecycle)
        XCTAssertEqual(replayed.sequence, manual.sequence)
        XCTAssertEqual(replayed.conversation.turns.map(\.text), manual.conversation.turns.map(\.text))
    }

    func testBranchComparisonReportsObjectiveChange() {
        let original = EncounterState(lifecycle: .active)
        let checkpoint = Branching.checkpoint(original)
        var retry = Branching.restore(checkpoint)
        retry.objectives[0].status = .satisfied
        let comparison = BranchComparator.compare(original: original, retry: retry)
        XCTAssertNotEqual(comparison.originalBranchID, comparison.retryBranchID)
        XCTAssertEqual(comparison.objectiveStatusChanges["architectureReasoning"], .satisfied)
    }

    func testObjectiveGraphRespectsDependencies() {
        var state = EncounterState(lifecycle: .active)
        XCTAssertEqual(ObjectiveGraph.nextEligible(in: state)?.id, "architectureReasoning")
        state.objectives[0].status = .satisfied
        XCTAssertEqual(ObjectiveGraph.nextEligible(in: state)?.id, "tradeoffAwareness")
    }

    func testCounterpartMemoryKeepsHigherImportanceEvidence() {
        let turnA = UUID(), turnB = UUID()
        var memory = [MemoryItem(sourceTurnID: turnA, topic: "architectureReasoning", summary: "weak", importance: 0.65)]
        CounterpartMemory.merge([.init(sourceTurnID: turnB, topic: "architectureReasoning", summary: "strong", importance: 0.95)], into: &memory)
        XCTAssertEqual(memory.count, 1)
        XCTAssertEqual(memory.first?.summary, "strong")
        XCTAssertEqual(memory.first?.sourceTurnID, turnB)
    }

    func testSurpriseCooldownPreventsBackToBackSurprises() {
        var state = EncounterState(lifecycle: .active)
        state.pressure.base = 0.8
        state.user.totalTurns = 3
        state.lastSurpriseTurn = 2
        XCTAssertNil(SurpriseEngine.next(for: state))
        state.user.totalTurns = 4
        XCTAssertNotNil(SurpriseEngine.next(for: state))
    }

    func testCheckpointPolicyDoesNotCheckpointEveryOrdinaryTurn() {
        let state = EncounterState(lifecycle: .active)
        let ordinary = AnswerEvaluation(answeredQuestion: true, relevance: 0.8, specificity: 0.65)
        XCTAssertNil(CheckpointPolicy.reason(state: state, evaluation: ordinary, moment: nil))
    }

    func testCheckpointPolicyCapturesObjectiveProgress() {
        let state = EncounterState(lifecycle: .active)
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.9, specificity: 0.8, objectiveEvaluations: [
            .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "clear", confidence: 0.9)
        ])
        XCTAssertEqual(CheckpointPolicy.reason(state: state, evaluation: evaluation, moment: nil), .objectiveProgress)
    }

    func testMultiTurnInterviewAdaptsPolicyAcrossObjectives() {
        var state = LiveStateReducer.reduce(state: .init(), event: .encounterStarted).state

        let first = EncounterFixture.apply(.init(
            text: "We chose Next.js because SSR helped discoverability, but it increased server complexity.",
            evaluation: .init(answeredQuestion: true, relevance: 0.95, specificity: 0.9, objectiveEvaluations: [
                .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explained SSR motivation.", confidence: 0.95),
                .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Named server complexity.", confidence: 0.92)
            ])
        ), to: state)
        state = first.state
        XCTAssertTrue(first.effects.contains(.requestCounterpartAction(.deepenFollowUp)))

        state = LiveStateReducer.reduce(state: state, event: .counterpartResponded("Tell me about a production issue you handled.")).state

        let second = EncounterFixture.apply(.init(
            text: "We had a cache invalidation issue after deployment and fixed the revalidation strategy.",
            evaluation: .init(answeredQuestion: true, relevance: 0.96, specificity: 0.88, objectiveEvaluations: [
                .init(objectiveID: "productionExperience", status: .satisfied, reason: "Gave a concrete production incident and response.", confidence: 0.94)
            ])
        ), to: state)
        state = second.state

        XCTAssertEqual(state.objectives.first(where: { $0.id == "productionExperience" })?.status, .satisfied)
        XCTAssertEqual(state.counterpart.memory.count, 3)
        XCTAssertTrue(second.effects.contains(.requestCounterpartAction(.acknowledgeAndContinue)))
        XCTAssertEqual(state.user.totalTurns, 2)
    }

    func testTakeAnotherCreatesAlternateBranchAndImprovesObjective() {
        var state = LiveStateReducer.reduce(state: .init(), event: .encounterStarted).state

        let weak = EncounterFixture.apply(.init(
            text: "Next.js is fast and popular.",
            evaluation: .init(answeredQuestion: true, relevance: 0.7, specificity: 0.3)
        ), to: state)
        state = weak.state

        // Create the retry point explicitly for the fixture: production uses the nearest
        // meaningful checkpoint selected by CheckpointPolicy.
        let retryPoint = Branching.checkpoint(state)
        let original = state
        let session = RetryEngine.begin(from: retryPoint, original: original)
        XCTAssertNotEqual(session.original.activeBranchID, session.retry.activeBranchID)

        let improved = EncounterFixture.apply(.init(
            text: "We chose Next.js for SSR on discoverable pages; the tradeoff was extra server complexity.",
            evaluation: .init(answeredQuestion: true, relevance: 0.96, specificity: 0.9, objectiveEvaluations: [
                .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explained why SSR was needed.", confidence: 0.96),
                .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Named the server-complexity tradeoff.", confidence: 0.93)
            ])
        ), to: session.retry)

        let comparison = RetryEngine.compare(session, retryState: improved.state)
        XCTAssertEqual(comparison.objectiveStatusChanges["architectureReasoning"], .satisfied)
        XCTAssertEqual(comparison.objectiveStatusChanges["tradeoffAwareness"], .satisfied)
        XCTAssertEqual(improved.state.moments.last?.kind, .strong)
    }

    func testRetryPreservesPreCheckpointHistory() {
        var state = EncounterState(lifecycle: .active)
        state = LiveStateReducer.reduce(state: state, event: .counterpartResponded("Why Next.js?")).state
        let checkpoint = Branching.checkpoint(state)
        let retry = RetryEngine.begin(from: checkpoint, original: state).retry
        XCTAssertEqual(retry.conversation.turns.map(\.text), ["Why Next.js?"])
        XCTAssertNotEqual(retry.activeBranchID, state.activeBranchID)
    }

    func testReplayReconstructsExactStateIncludingGeneratedIdentity() {
        let initial = EncounterState(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            activeBranchID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let events: [RecordedEvent] = [
            .init(sequence: 1, event: .encounterStarted),
            .init(sequence: 2, event: .counterpartResponded("Why did you choose Next.js?")),
            .init(sequence: 3, event: .userSubmitted("SSR improved discoverability."))
        ]

        let first = ReplayEngine.replay(initial: initial, events: events)
        let second = ReplayEngine.replay(initial: initial, events: events)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.conversation.turns, second.conversation.turns)
    }

    func testPersistedEventEnvelopeCanDriveReplay() {
        let initial = EncounterState(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            activeBranchID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let started = LiveStateReducer.reduce(state: initial, event: .encounterStarted)
        let submitted = LiveStateReducer.reduce(state: started.state, event: .userSubmitted("A persisted answer"))

        let records = (started.effects + submitted.effects).compactMap { effect -> EventRecord? in
            if case let .persistEvent(record) = effect { return record }
            return nil
        }

        let replayed = ReplayEngine.replay(initial: initial, records: records)
        XCTAssertEqual(replayed, submitted.state)
        XCTAssertEqual(records.map(\.schemaVersion), [1, 1])
        XCTAssertEqual(records.map(\.kind), ["encounterStarted", "userSubmitted"])
    }

    func testDeterministicReductionProducesSameEventEnvelope() {
        let state = EncounterState(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            activeBranchID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let first = LiveStateReducer.reduce(state: state, event: .userSubmitted("Same input"))
        let second = LiveStateReducer.reduce(state: state, event: .userSubmitted("Same input"))
        XCTAssertEqual(first.state, second.state)
        XCTAssertEqual(first.effects, second.effects)
    }

}
