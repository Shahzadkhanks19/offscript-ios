import Foundation

public struct EvaluatedUserTurn: Equatable, Sendable {
    public let text: String
    public let evaluation: AnswerEvaluation
    public init(text: String, evaluation: AnswerEvaluation) {
        self.text = text; self.evaluation = evaluation
    }
}

public struct FixtureStepResult: Sendable {
    public let state: EncounterState
    public let effects: [SimulationEffect]
    public let checkpoint: Checkpoint?
    public init(state: EncounterState, effects: [SimulationEffect], checkpoint: Checkpoint?) {
        self.state = state; self.effects = effects; self.checkpoint = checkpoint
    }
}

public enum EncounterFixture {
    public static func apply(_ turn: EvaluatedUserTurn, to initial: EncounterState) -> FixtureStepResult {
        let submitted = LiveStateReducer.reduce(state: initial, event: .userSubmitted(turn.text))
        guard case let .evaluateAnswer(turnID, _) = submitted.effects.first(where: {
            if case .evaluateAnswer = $0 { return true }
            return false
        }) else {
            return .init(state: submitted.state, effects: submitted.effects, checkpoint: nil)
        }

        let evaluated = LiveStateReducer.reduce(
            state: submitted.state,
            event: .answerEvaluated(turnID: turnID, turn.evaluation)
        )
        let checkpoint = evaluated.effects.compactMap { effect -> Checkpoint? in
            if case let .persistCheckpoint(value) = effect { return value }
            return nil
        }.first
        return .init(state: evaluated.state, effects: submitted.effects + evaluated.effects, checkpoint: checkpoint)
    }
}
