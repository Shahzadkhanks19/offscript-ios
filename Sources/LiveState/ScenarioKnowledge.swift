import Foundation

/// Information intentionally separated by visibility. Private user context may
/// inform coaching/evaluation, but it must never leak into counterpart prompts.
public struct ScenarioKnowledge: Equatable, Sendable, Codable {
    public var counterpartVisible: [KnowledgeItem]
    public var privateUserContext: [KnowledgeItem]

    public init(counterpartVisible: [KnowledgeItem] = [], privateUserContext: [KnowledgeItem] = []) {
        self.counterpartVisible = counterpartVisible
        self.privateUserContext = privateUserContext
    }

    public var counterpartContext: [KnowledgeItem] { counterpartVisible }
}

public struct KnowledgeItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let value: String

    public init(id: String, value: String) {
        self.id = id
        self.value = value
    }
}
