import Foundation

public enum SimulationEvent: Equatable, Sendable, Codable {
    case preparationStarted
    case preparationCompleted
    case encounterStarting
    case encounterStarted
    case userSubmitted(String)
    case counterpartResponded(String)
    case answerEvaluated(turnID: UUID, AnswerEvaluation)
    case checkpointRestored(Checkpoint)
    case pressureAdjusted(Double)
    case surpriseTriggered(Surprise)
    case surpriseCleared(UUID)
    case observableSignalsUpdated([ObservableSignal])
    case guardrailActionChanged(GuardrailAction)
    case encounterPaused
    case encounterResumed
    case encounterEnding
    case encounterProcessing
    case encounterCompleted
    case reviewStarted
    case retryStarted
}

public enum SimulationEffect: Equatable, Sendable {
    case dispatchEvent(SimulationEvent)
    case evaluateAnswer(turnID: UUID, text: String)
    case requestCounterpartAction(PolicyAction)
    case persistCheckpoint(Checkpoint)
    case persistEvent(EventRecord)
    case presentMoment(Moment)
    case presentSurprise(Surprise)
}

/// Persisted event envelope. Unlike the old kind-only record, this retains the
/// complete typed event needed to reconstruct an encounter.
public struct EventRecord: Identifiable, Equatable, Sendable, Codable {
    public static let currentSchemaVersion = 2

    public let id: UUID
    public let schemaVersion: Int
    public let encounterID: UUID?
    public let branchID: UUID?
    public let sequence: Int
    public let timestamp: Date
    public let event: SimulationEvent

    public init(
        id: UUID,
        schemaVersion: Int = EventRecord.currentSchemaVersion,
        encounterID: UUID? = nil,
        branchID: UUID? = nil,
        sequence: Int,
        timestamp: Date,
        event: SimulationEvent
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.encounterID = encounterID
        self.branchID = branchID
        self.sequence = sequence
        self.timestamp = timestamp
        self.event = event
    }

    public var kind: String {
        switch event {
        case .preparationStarted: "preparationStarted"
        case .preparationCompleted: "preparationCompleted"
        case .encounterStarting: "encounterStarting"
        case .encounterStarted: "encounterStarted"
        case .userSubmitted: "userSubmitted"
        case .counterpartResponded: "counterpartResponded"
        case .answerEvaluated: "answerEvaluated"
        case .checkpointRestored: "checkpointRestored"
        case .pressureAdjusted: "pressureAdjusted"
        case .surpriseTriggered: "surpriseTriggered"
        case .surpriseCleared: "surpriseCleared"
        case .observableSignalsUpdated: "observableSignalsUpdated"
        case .guardrailActionChanged: "guardrailActionChanged"
        case .encounterPaused: "encounterPaused"
        case .encounterResumed: "encounterResumed"
        case .encounterEnding: "encounterEnding"
        case .encounterProcessing: "encounterProcessing"
        case .encounterCompleted: "encounterCompleted"
        case .reviewStarted: "reviewStarted"
        case .retryStarted: "retryStarted"
        }
    }
}
