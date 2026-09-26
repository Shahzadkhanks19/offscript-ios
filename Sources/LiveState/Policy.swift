import Foundation

public enum PolicyAction: String, Equatable, Sendable, Codable {
    case askOpeningQuestion, acknowledgeAndContinue, challengeTradeoff, askForSpecificExample, deepenFollowUp, closeTopic, endEncounter
}

public enum PolicyEngine {
    public static func nextAction(for state: EncounterState, evaluation: AnswerEvaluation?) -> PolicyAction {
        guard let evaluation else { return .askOpeningQuestion }
        if !evaluation.answeredQuestion || evaluation.relevance < 0.45 { return .askForSpecificExample }
        if evaluation.specificity < 0.55 { return .askForSpecificExample }

        let tradeoff = state.objectives.first(where: { $0.id == "tradeoffAwareness" })
        if tradeoff?.status != .satisfied { return .challengeTradeoff }

        let production = state.objectives.first(where: { $0.id == "productionExperience" })
        if production?.status != .satisfied { return .deepenFollowUp }

        return .acknowledgeAndContinue
    }
}
