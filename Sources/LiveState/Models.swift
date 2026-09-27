import Foundation

public enum Speaker: String, Sendable, Codable { case user, counterpart }
public enum EncounterLifecycle: String, Sendable, Codable {
    case created, preparing, ready, starting, active, ending, processing, completed, reviewing, retrying
    case paused, recovering, failed, cancelled
}
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

public struct ScenarioState: Equatable, Sendable, Codable {\n    public var domain: EncounterDomain\n    public var title: String\n    public var role: String\n    public var company: String?\n    public var phase: String\n    public var knowledge: ScenarioKnowledge\n\n    public init(\n        domain: EncounterDomain = .interview,\n        title: String = "Frontend Developer Interview",\n        role: String = "Frontend Developer",\n        company: String? = nil,\n        phase: String = "opening",\n        knowledge: ScenarioKnowledge = .init()\n    ) {\n        self.domain = domain; self.title = title; self.role = role; self.company = company; self.phase = phase; self.knowledge = knowledge\n    }\n\n    private enum CodingKeys: String, CodingKey {\n        case domain, title, role, company, phase, knowledge\n    }\n\n    public init(from decoder: Decoder) throws {\n        let container = try decoder.container(keyedBy: CodingKeys.self)\n        // domain was introduced after the first persisted ScenarioState shape.\n        // Old snapshots were interview-only, so missing domain migrates safely.\n        domain = try container.decodeIfPresent(EncounterDomain.self, forKey: .domain) ?? .interview\n        title = try container.decode(String.self, forKey: .title)\n        role = try container.decode(String.self, forKey: .role)\n        company = try container.decodeIfPresent(String.self, forKey: .company)\n        phase = try container.decode(String.self, forKey: .phase)\n        knowledge = try container.decode(ScenarioKnowledge.self, forKey: .knowledge)\n    }\n}

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
    public var latestSignals: [ObservableSignal] = []
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
    public var guardrails: GuardrailState
    public var activeBranchID: UUID
    public var sequence: Int
    public var moments: [Moment]
    public var pendingSurprise: Surprise?
    public var lastSurpriseTurn: Int?
    public var surpriseCount: Int
    public var surpriseBudget: Int
    public var branchLineage: BranchLineage
    public var metadata: EngineMetadata

    public init(
        id: UUID = UUID(),
        lifecycle: EncounterLifecycle = .created,
        scenario: ScenarioState = .init(),
        counterpart: CounterpartState = .init(),
        conversation: ConversationState = .init(),
        user: ObservableUserState = .init(),
        objectives: [Objective] = [.init(id: "architectureReasoning"), .init(id: "tradeoffAwareness"), .init(id: "productionExperience")],
        pressure: PressureState = .init(),
        guardrails: GuardrailState = .init(),
        activeBranchID: UUID = UUID(),
        sequence: Int = 0,
        moments: [Moment] = [],
        pendingSurprise: Surprise? = nil,
        lastSurpriseTurn: Int? = nil,
        surpriseCount: Int = 0,
        surpriseBudget: Int = 2,
        branchLineage: BranchLineage = .init(),
        metadata: EngineMetadata = .init()
    ) {
        self.id = id; self.lifecycle = lifecycle; self.scenario = scenario; self.counterpart = counterpart
        self.conversation = conversation; self.user = user; self.objectives = objectives; self.pressure = pressure; self.guardrails = guardrails
        self.activeBranchID = activeBranchID; self.sequence = sequence; self.moments = moments; self.pendingSurprise = pendingSurprise; self.lastSurpriseTurn = lastSurpriseTurn
        self.surpriseCount = max(0, surpriseCount); self.surpriseBudget = max(0, surpriseBudget); self.branchLineage = branchLineage; self.metadata = metadata
    }
}
