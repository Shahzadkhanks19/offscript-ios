import Foundation

public struct ObjectiveDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let dependencies: [String]
    public let priority: Int
    public init(id: String, dependencies: [String] = [], priority: Int) {
        self.id = id; self.dependencies = dependencies; self.priority = priority
    }
}

public enum ObjectiveGraph {
    public static let interview: [ObjectiveDefinition] = [
        .init(id: "architectureReasoning", priority: 100),
        .init(id: "tradeoffAwareness", dependencies: ["architectureReasoning"], priority: 90),
        .init(id: "productionExperience", dependencies: ["architectureReasoning"], priority: 80)
    ]

    public static func nextEligible(in state: EncounterState, definitions: [ObjectiveDefinition] = interview) -> ObjectiveDefinition? {
        definitions
            .filter { definition in
                guard state.objectives.first(where: { $0.id == definition.id })?.status != .satisfied else { return false }
                return definition.dependencies.allSatisfy { dependency in
                    state.objectives.first(where: { $0.id == dependency })?.status == .satisfied
                }
            }
            .sorted { $0.priority > $1.priority }
            .first
    }
}
