import Foundation

public enum SurpriseKind: String, Equatable, Sendable, Codable {
    case constraintChange, skepticalChallenge, interruption, deeperProbe
}

public struct Surprise: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let kind: SurpriseKind
    public let targetObjectiveID: String
    public let reason: String
    public init(id: UUID = UUID(), kind: SurpriseKind, targetObjectiveID: String, reason: String) {
        self.id = id; self.kind = kind; self.targetObjectiveID = targetObjectiveID; self.reason = reason
    }
}

public enum SurpriseEngine {
    public static func next(for state: EncounterState) -> Surprise? {
        guard state.pressure.effective >= 0.55, state.user.totalTurns >= 2 else { return nil }
        if let unresolved = state.objectives.first(where: { $0.status != .satisfied }) {
            let kind: SurpriseKind = unresolved.id == "tradeoffAwareness" ? .skepticalChallenge : .deeperProbe
            return Surprise(kind: kind, targetObjectiveID: unresolved.id, reason: "Probe an unresolved encounter objective.")
        }
        return nil
    }
}
