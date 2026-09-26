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
