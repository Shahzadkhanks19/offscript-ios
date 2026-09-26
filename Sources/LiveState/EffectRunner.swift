import Foundation

public protocol EvaluationService: Sendable {
    func evaluate(turnID: UUID, text: String, context: EvaluationContext) async throws -> AnswerEvaluation
}

public protocol CounterpartService: Sendable {
    func respond(to action: PolicyAction, context: CounterpartContext) async throws -> String
}

public protocol CheckpointStore: Sendable {
    func save(_ checkpoint: Checkpoint) async throws
}

public protocol EventStore: Sendable {
    func save(_ record: EventRecord) async throws
}

/// Executes side effects outside the reducer and converts service results back
/// into typed SimulationEvents. Services never mutate EncounterState directly.
public struct EffectRunner: Sendable {
    public let evaluation: any EvaluationService
    public let counterpart: any CounterpartService
    public let checkpoints: any CheckpointStore
    public let events: any EventStore

    public init(
        evaluation: any EvaluationService,
        counterpart: any CounterpartService,
        checkpoints: any CheckpointStore,
        events: any EventStore
    ) {
        self.evaluation = evaluation
        self.counterpart = counterpart
        self.checkpoints = checkpoints
        self.events = events
    }

    public func run(_ effect: SimulationEffect, state: EncounterState) async throws -> SimulationEvent? {
        switch effect {
        case let .dispatchEvent(event):
            return event
        case let .evaluateAnswer(turnID, text):
            return .answerEvaluated(
                turnID: turnID,
                try await evaluation.evaluate(turnID: turnID, text: text, context: EvaluationContext(state: state))
            )
        case let .requestCounterpartAction(action):
            return .counterpartResponded(try await counterpart.respond(to: action, context: CounterpartContext(state: state)))
        case let .persistCheckpoint(checkpoint):
            try await checkpoints.save(checkpoint)
            return nil
        case let .persistEvent(record):
            try await events.save(record)
            return nil
        case .presentMoment, .presentSurprise:
            return nil
        }
    }
}
