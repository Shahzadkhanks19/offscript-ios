import Foundation

public enum MomentKind: String, Equatable, Sendable, Codable { case strong, worthRevisiting, turningPoint }

public struct Moment: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let turnID: UUID
    public let kind: MomentKind
    public let reason: String
    public let evidenceObjectiveIDs: [String]
    public init(id: UUID = UUID(), turnID: UUID, kind: MomentKind, reason: String, evidenceObjectiveIDs: [String]) {
        self.id = id; self.turnID = turnID; self.kind = kind; self.reason = reason; self.evidenceObjectiveIDs = evidenceObjectiveIDs
    }
}

public enum MomentEngine {
    public static func detect(turnID: UUID, evaluation: AnswerEvaluation) -> Moment? {
        let satisfied = evaluation.objectiveEvaluations.filter { $0.status == .satisfied }.map(\.objectiveID)
        if satisfied.count >= 2 && evaluation.specificity >= 0.7 {
            return Moment(turnID: turnID, kind: .strong, reason: "Specific answer advanced multiple objectives.", evidenceObjectiveIDs: satisfied)
        }
        if !evaluation.answeredQuestion || evaluation.relevance < 0.45 {
            return Moment(turnID: turnID, kind: .turningPoint, reason: "The response did not directly address the active question.", evidenceObjectiveIDs: [])
        }
        if evaluation.specificity < 0.55 {
            return Moment(turnID: turnID, kind: .worthRevisiting, reason: "The response would benefit from a concrete example.", evidenceObjectiveIDs: satisfied)
        }
        return nil
    }
}
