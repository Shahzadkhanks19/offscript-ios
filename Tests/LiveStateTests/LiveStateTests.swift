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
}
