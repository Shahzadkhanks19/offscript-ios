import XCTest
@testable import LiveState

final class DurableResultValidatorTests: XCTestCase {
    func testEvaluationResultMustMatchIntentTurn() throws {
        let state = EncounterState(lifecycle: .active)
        let expectedTurnID = UUID()
        let intent = DurableEffectIntent(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            originatingSequence: state.sequence,
            effectIndex: 0,
            payload: .evaluateAnswer(turnID: expectedTurnID, text: "answer"),
            state: state
        )
        let wrongResult = SimulationEvent.answerEvaluated(
            turnID: UUID(),
            .init(answeredQuestion: true, relevance: 1, specificity: 1)
        )

        XCTAssertThrowsError(try DurableResultValidator.validate(wrongResult, for: intent)) { error in
            XCTAssertEqual(error as? RuntimeJournalError, .invalidResult(intentID: intent.id))
        }
    }

    func testDispatchResultMustExactlyMatchExpectedEvent() throws {
        let state = EncounterState(lifecycle: .active)
        let expected = SimulationEvent.pressureAdjusted(0.4)
        let intent = DurableEffectIntent(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            originatingSequence: state.sequence,
            effectIndex: 0,
            payload: .dispatchEvent(expected),
            state: state
        )

        XCTAssertNoThrow(try DurableResultValidator.validate(expected, for: intent))
        XCTAssertThrowsError(
            try DurableResultValidator.validate(.pressureAdjusted(0.8), for: intent)
        ) { error in
            XCTAssertEqual(error as? RuntimeJournalError, .invalidResult(intentID: intent.id))
        }
    }

    func testCheckpointIntentCannotOwnResultEvent() {
        let state = EncounterState(lifecycle: .active)
        let checkpoint = Checkpoint(
            id: UUID(),
            parentBranchID: state.activeBranchID,
            state: state
        )
        let intent = DurableEffectIntent(
            id: UUID(),
            encounterID: state.id,
            branchID: state.activeBranchID,
            originatingSequence: state.sequence,
            effectIndex: 0,
            payload: .persistCheckpoint(checkpoint),
            state: state
        )

        XCTAssertThrowsError(
            try DurableResultValidator.validate(.counterpartResponded("invalid"), for: intent)
        ) { error in
            XCTAssertEqual(error as? RuntimeJournalError, .invalidResult(intentID: intent.id))
        }
    }
}
