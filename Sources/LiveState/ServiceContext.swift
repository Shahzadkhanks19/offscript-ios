import Foundation

/// Minimal context permitted to reach the counterpart-generation service.
/// Private user knowledge is intentionally absent from this type.
public struct CounterpartContext: Equatable, Sendable {
    public let scenarioTitle: String
    public let role: String
    public let company: String?
    public let phase: String
    public let visibleKnowledge: [KnowledgeItem]
    public let counterpart: CounterpartState
    public let conversation: ConversationState
    public let pressure: PressureState
    public let pendingSurprise: Surprise?

    public init(state: EncounterState) {
        scenarioTitle = state.scenario.title
        role = state.scenario.role
        company = state.scenario.company
        phase = state.scenario.phase
        visibleKnowledge = state.scenario.knowledge.counterpartVisible
        counterpart = state.counterpart
        conversation = state.conversation
        pressure = state.pressure
        pendingSurprise = state.pendingSurprise
    }
}

/// Evaluation may use explicitly private coaching context, but still receives a
/// projection rather than the authoritative EncounterState.
public struct EvaluationContext: Equatable, Sendable {
    public let scenarioTitle: String
    public let role: String
    public let phase: String
    public let visibleKnowledge: [KnowledgeItem]
    public let privateUserContext: [KnowledgeItem]
    public let currentQuestion: String?
    public let objectives: [Objective]
    public let observableUser: ObservableUserState

    public init(state: EncounterState) {
        scenarioTitle = state.scenario.title
        role = state.scenario.role
        phase = state.scenario.phase
        visibleKnowledge = state.scenario.knowledge.counterpartVisible
        privateUserContext = state.scenario.knowledge.privateUserContext
        currentQuestion = state.conversation.currentQuestion
        objectives = state.objectives
        observableUser = state.user
    }
}
