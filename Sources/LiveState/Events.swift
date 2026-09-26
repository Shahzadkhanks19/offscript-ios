import Foundation

public enum SimulationEvent: Equatable, Sendable {
    case encounterStarted
    case userSubmitted(String)
    case counterpartResponded(String)
    case answerEvaluated(turnID: UUID, AnswerEvaluation)
    case checkpointRestored(Checkpoint)
    case pressureAdjusted(Double)
    case encounterPaused
    case encounterResumed
    case encounterCompleted
}

public enum SimulationEffect: Equatable, Sendable {
    case evaluateAnswer(turnID: UUID, text: String)
    case requestCounterpartAction(PolicyAction)
    case persistCheckpoint(Checkpoint)
    case persistEvent(EventRecord)
}

public struct EventRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sequence: Int
    public let kind: String
    public let timestamp: Date
    public init(id: UUID = UUID(), sequence: Int, kind: String, timestamp: Date = Date()) {
        self.id = id; self.sequence = sequence; self.kind = kind; self.timestamp = timestamp
    }
}
