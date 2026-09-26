import Foundation

public enum SimulationEvent: Equatable, Sendable {
    case encounterStarted
    case userSubmitted(String)
    case counterpartResponded(String)
    case answerEvaluated(turnID: UUID, AnswerEvaluation)
    case checkpointRestored(Checkpoint)
    case pressureAdjusted(Double)
    case surpriseTriggered(Surprise)
    case encounterPaused
    case encounterResumed
    case encounterCompleted
}

public enum SimulationEffect: Equatable, Sendable {
    case evaluateAnswer(turnID: UUID, text: String)
    case requestCounterpartAction(PolicyAction)
    case persistCheckpoint(Checkpoint)
    case persistEvent(EventRecord)
    case presentMoment(Moment)
    case presentSurprise(Surprise)
}

/// Persisted event envelope. Unlike the old kind-only record, this retains the
/// complete typed event needed to reconstruct an encounter.
public struct EventRecord: Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let schemaVersion: Int
    public let sequence: Int
    public let timestamp: Date
    public let event: SimulationEvent

    public init(
        id: UUID,
        schemaVersion: Int = EventRecord.currentSchemaVersion,
        sequence: Int,
        timestamp: Date,
        event: SimulationEvent
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.timestamp = timestamp
        self.event = event
    }

    public var kind: String {
        switch event {
        case .encounterStarted: "encounterStarted"
        case .userSubmitted: "userSubmitted"
        case .counterpartResponded: "counterpartResponded"
        case .answerEvaluated: "answerEvaluated"
        case .checkpointRestored: "checkpointRestored"
        case .pressureAdjusted: "pressureAdjusted"
        case .surpriseTriggered: "surpriseTriggered"
        case .encounterPaused: "encounterPaused"
        case .encounterResumed: "encounterResumed"
        case .encounterCompleted: "encounterCompleted"
        }
    }
}
