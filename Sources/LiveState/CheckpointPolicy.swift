import Foundation

public enum CheckpointReason: String, Equatable, Sendable, Codable { case objectiveProgress, turningPoint, surprise, periodic }

public enum CheckpointPolicy {
    public static func reason(state: EncounterState, evaluation: AnswerEvaluation, moment: Moment?) -> CheckpointReason? {
        if moment?.kind == .turningPoint { return .turningPoint }
        if evaluation.objectiveEvaluations.contains(where: { $0.status == .satisfied }) { return .objectiveProgress }
        if state.user.totalTurns > 0 && state.user.totalTurns.isMultiple(of: 3) { return .periodic }
        return nil
    }
}
