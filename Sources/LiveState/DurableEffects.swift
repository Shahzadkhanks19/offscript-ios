import Foundation

public enum DurableEffectPayload: Equatable, Sendable, Codable {
    case dispatchEvent(SimulationEvent)
    case evaluateAnswer(turnID: UUID, text: String)
    case requestCounterpartAction(PolicyAction)
    case persistCheckpoint(Checkpoint)

    public init?(_ effect: SimulationEffect) {
        switch effect {
        case let .dispatchEvent(event): self = .dispatchEvent(event)
        case let .evaluateAnswer(turnID, text): self = .evaluateAnswer(turnID: turnID, text: text)
        case let .requestCounterpartAction(action): self = .requestCounterpartAction(action)
        case let .persistCheckpoint(checkpoint): self = .persistCheckpoint(checkpoint)
        case .persistEvent, .presentMoment, .presentSurprise: return nil
        }
    }

    public var effect: SimulationEffect {
        switch self {
        case let .dispatchEvent(event): .dispatchEvent(event)
        case let .evaluateAnswer(turnID, text): .evaluateAnswer(turnID: turnID, text: text)
        case let .requestCounterpartAction(action): .requestCounterpartAction(action)
        case let .persistCheckpoint(checkpoint): .persistCheckpoint(checkpoint)
        }
    }
}

public struct DurableEffectIntent: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let encounterID: UUID
    public let branchID: UUID
    public let originatingSequence: Int
    public let effectIndex: Int
    public let payload: DurableEffectPayload
    public let state: EncounterState

    public init(
        id: UUID,
        encounterID: UUID,
        branchID: UUID,
        originatingSequence: Int,
        effectIndex: Int,
        payload: DurableEffectPayload,
        state: EncounterState
    ) {
        self.id = id
        self.encounterID = encounterID
        self.branchID = branchID
        self.originatingSequence = originatingSequence
        self.effectIndex = effectIndex
        self.payload = payload
        self.state = state
    }
}

public enum DurableEffectPlanner {
    public static func intents(effects: [SimulationEffect], state: EncounterState) -> [DurableEffectIntent] {
        effects.enumerated().compactMap { index, effect in
            guard let payload = DurableEffectPayload(effect) else { return nil }
            return DurableEffectIntent(
                id: Determinism.id(
                    encounterID: state.id,
                    sequence: state.sequence,
                    domain: "effect-intent",
                    index: index
                ),
                encounterID: state.id,
                branchID: state.activeBranchID,
                originatingSequence: state.sequence,
                effectIndex: index,
                payload: payload,
                state: state
            )
        }
    }
}

/// Persistence boundary for a transactional outbox. Production implementations
/// must append an event and its derived durable intents atomically.
public enum RuntimeJournalError: Error, Equatable, Sendable {
    case eventConflict(id: UUID)
    case sequenceConflict(encounterID: UUID, sequence: Int)
    case intentConflict(id: UUID)
}

/// Storage contract for the transactional event journal + durable outbox.
///
/// Implementations MUST make commit idempotent:
/// - replaying the exact same event/intent transaction is a no-op;
/// - the same event ID or encounter sequence with different content conflicts;
/// - the same intent ID with different content conflicts;
/// - completing an already-completed intent is a no-op.
public protocol RuntimeJournal: Sendable {
    func commit(
        event: EventRecord,
        intents: [DurableEffectIntent],
        completing intentID: UUID?
    ) async throws
    func pendingIntents(encounterID: UUID) async throws -> [DurableEffectIntent]
    func markCompleted(intentID: UUID) async throws
}
