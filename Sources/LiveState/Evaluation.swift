import Foundation

public struct ObjectiveEvaluation: Equatable, Sendable, Codable {
    public let objectiveID: String
    public let status: ObjectiveStatus
    public let reason: String
    public let confidence: Double
    public init(objectiveID: String, status: ObjectiveStatus, reason: String, confidence: Double) {
        self.objectiveID = objectiveID; self.status = status; self.reason = reason; self.confidence = confidence
    }
}

public struct AnswerEvaluation: Equatable, Sendable, Codable {
    public var answeredQuestion: Bool
    public var relevance: Double
    public var specificity: Double
    public var objectiveEvaluations: [ObjectiveEvaluation]
    public init(answeredQuestion: Bool, relevance: Double, specificity: Double, objectiveEvaluations: [ObjectiveEvaluation] = []) {
        self.answeredQuestion = answeredQuestion
        self.relevance = min(max(relevance, 0), 1)
        self.specificity = min(max(specificity, 0), 1)
        self.objectiveEvaluations = objectiveEvaluations
    }
}
