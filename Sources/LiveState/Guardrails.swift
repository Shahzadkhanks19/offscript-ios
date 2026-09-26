import Foundation

public enum EncounterDomain: String, Equatable, Sendable, Codable {
    case interview, workplace, education, negotiation, presentation
}

public enum GuardrailAction: String, Equatable, Sendable, Codable {
    case none, redirect, endEncounter
}

public struct GuardrailState: Equatable, Sendable, Codable {
    public var allowedDomains: Set<EncounterDomain>
    public var action: GuardrailAction

    public init(allowedDomains: Set<EncounterDomain> = [.interview], action: GuardrailAction = .none) {
        self.allowedDomains = allowedDomains
        self.action = action
    }
}

/// Pure, deterministic domain gate. Models may help classify content later,
/// but only LiveState policy converts trusted inputs into authoritative action.
public enum GuardrailPolicy {
    public static func action(
        for domain: EncounterDomain,
        state: GuardrailState
    ) -> GuardrailAction {
        state.allowedDomains.contains(domain) ? .none : .redirect
    }

    public static func event(
        for domain: EncounterDomain,
        state: GuardrailState
    ) -> SimulationEvent? {
        let next = action(for: domain, state: state)
        guard next != state.action else { return nil }
        return .guardrailActionChanged(next)
    }

    public static func event(for encounter: EncounterState) -> SimulationEvent? {
        event(for: encounter.scenario.domain, state: encounter.guardrails)
    }
}
