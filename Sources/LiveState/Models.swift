import Foundation

public enum Speaker: String, Sendable, Codable { case user, counterpart }
public enum EncounterLifecycle: String, Sendable, Codable { case created, preparing, ready, active, paused, recovering, completed, failed, cancelled }
public enum TurnState: String, Sendable, Codable { case idle, userSpeaking, counterpartThinking, counterpartSpeaking, overlap, silence, paused }
public enum ObjectiveStatus: String, Sendable, Codable { case unresolved, partial, satisfied }

public struct Evidence: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let turnID: UUID
    public let reason: String
    public let confidence: Double
    public init(id: UUID = UUID(), turnID: UUID, reason: String, confidence: Double) {
        self.id = id; self.turnID = turnID; self.reason = reason; self.confidence = min(max(confidence, 0), 1)
    }
}

public struct Objective: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public var status: ObjectiveStatus
    public var evidence: [Evidence]
    public init(id: String, status: ObjectiveStatus = .unresolved, evidence: [Evidence] = []) {
        self.id = id; self.status = status; self.evidence = evidence
    }
}

public struct ConversationTurn: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    public let createdAt: Date
    public init(id: UUID = UUID(), speaker: Speaker, text: String, createdAt: Date = Date()) {
        self.id = id; self.speaker = speaker; self.text = text; self.createdAt = createdAt
    }
}

public struct ScenarioState: Equatable, Sendable, Codable {
    public var title: String
    public var role: String
    public var company: String?
    public var phase: String
    public init(title: String = "Frontend Developer Interview", role: String = "Frontend Developer", company: String? = nil, phase: String = "opening") {
        self.title = title; self.role = role; self.company = company; self.phase = phase
    }
}

public struct CounterpartState: Equatable, Sendable, Codable {
    public var name: String
    public var role: String
    public var patience: Double
    public var skepticism: Double
    public var engagement: Double
    public var rapport: Double
    public var memory: [MemoryItem]
    public init(name: String = "Maya Chen", role: String = "Senior Engineering Manager", patience: Double = 0.65, skepticism: Double = 0.55, engagement: Double = 0.65, rapport: Double = 0.5, memory: [MemoryItem] = []) {
        self.name = name; self.role = role
        self.patience = Self.clamp(patience); self.skepticism = Self.clamp(skepticism)
        self.engagement = Self.clamp(engagement); self.rapport = Self.clamp(rapport); self.memory = memory
    }
    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

public struct PressureState: Equatable, Sendable, Codable {
    public var base: Double
    public var adaptiveModifier: Double
    public var followUpDepth: Double
    public var interruptionFrequency: Double
    public var silenceTolerance: Double
    public init(base: Double = 0.5, adaptiveModifier: Double = 0, followUpDepth: Double = 0.5, interruptionFrequency: Double = 0.25, silenceTolerance: Double = 0.5) {
        self.base = base; self.adaptiveModifier = adaptiveModifier; self.followUpDepth = followUpDepth
        self.interruptionFrequency = interruptionFrequency; self.silenceTolerance = silenceTolerance
    }
    public var effective: Double { min(max(base + adaptiveModifier, 0), 1) }
}

public struct ObservableUserState: Equatable, Sendable, Codable {
    public var totalTurns: Int = 0
    public var interruptions: Int = 0
    public var averageTurnCharacterCount: Double = 0
    public init() {}
}

public struct ConversationState: Equatable, Sendable, Codable {
    public var turnState: TurnState = .idle
    public var turns: [ConversationTurn] = []
    public var currentQuestion: String?
    public init() {}
}

public struct EncounterState: Equatable, Sendable, Codable {
    public let id: UUID
    public var lifecycle: EncounterLifecycle
    public var scenario: ScenarioState
    public var counterpart: CounterpartState
    public var conversation: ConversationState
    public var user: ObservableUserState
    public var objectives: [Objective]
    public var pressure: PressureState
    public var activeBranchID: UUID
    public var sequence: Int
    public var moments: [Moment]
    public var pendingSurprise: Surprise?
    public var lastSurpriseTurn: Int?

    public init(
        id: UUID = UUID(),
        lifecycle: EncounterLifecycle = .created,
        scenario: ScenarioState = .init(),
        counterpart: CounterpartState = .init(),
        conversation: ConversationState = .init(),
        user: ObservableUserState = .init(),
        objectives: [Objective] = [.init(id: "architectureReasoning"), .init(id: "tradeoffAwareness"), .init(id: "productionExperience")],
        pressure: PressureState = .init(),
        activeBranchID: UUID = UUID(),
        sequence: Int = 0,
        moments: [Moment] = [],
        pendingSurprise: Surprise? = nil,
        lastSurpriseTurn: Int? = nil
    ) {
        self.id = id; self.lifecycle = lifecycle; self.scenario = scenario; self.counterpart = counterpart
        self.conversation = conversation; self.user = user; self.objectives = objectives; self.pressure = pressure
        self.activeBranchID = activeBranchID; self.sequence = sequence; self.moments = moments; self.pendingSurprise = pendingSurprise; self.lastSurpriseTurn = lastSurpriseTurn
    }
}
