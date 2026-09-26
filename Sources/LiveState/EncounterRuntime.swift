import Foundation

public struct PendingEffect: Equatable, Sendable {
    public let effect: SimulationEffect
    public let state: EncounterState

    public init(effect: SimulationEffect, state: EncounterState) {
        self.effect = effect
        self.state = state
    }
}

/// Coordinates the pure reducer with external services.
///
/// Durability rules:
/// 1. Event-derived state commits only after its EventRecord is persisted.
/// 2. If a post-commit effect fails, the durable state remains committed and
///    the failed effect plus all not-yet-run effects are retained for retry.
public actor EncounterRuntime {
    public private(set) var state: EncounterState
    public private(set) var pendingEffects: [PendingEffect] = []
    private let runner: EffectRunner
    private let journal: (any RuntimeJournal)?

    public init(
        state: EncounterState = .init(),
        pendingEffects: [PendingEffect] = [],
        runner: EffectRunner,
        journal: (any RuntimeJournal)? = nil
    ) {
        self.state = state
        self.pendingEffects = pendingEffects
        self.runner = runner
        self.journal = journal
    }

    /// Rebuilds authoritative state and unfinished durable work from an event
    /// stream after process relaunch. No recovered effect executes until the
    /// caller explicitly resumes it (or sends the next event).
    public static func recovering(
        initial: EncounterState,
        records: [EventRecord],
        runner: EffectRunner,
        journal: (any RuntimeJournal)? = nil
    ) throws -> EncounterRuntime {
        let recoveredState = try ReplayEngine.validatedReplay(initial: initial, records: records)
        let recoveredEffects = try EffectRecovery.pending(initial: initial, records: records)
        return EncounterRuntime(
            state: recoveredState,
            pendingEffects: recoveredEffects,
            runner: runner,
            journal: journal
        )
    }

    @discardableResult
    public func send(_ event: SimulationEvent) async throws -> EncounterState {
        try await resumePendingEffects()
        try await resumeJournalIntents()
        try await process(events: [event])
        return state
    }

    @discardableResult
    public func resumeJournalIntents() async throws -> EncounterState {
        guard let journal else { return state }
        let intents = try await journal.pendingIntents(encounterID: state.id)
            .sorted {
                if $0.originatingSequence == $1.originatingSequence {
                    return $0.effectIndex < $1.effectIndex
                }
                return $0.originatingSequence < $1.originatingSequence
            }

        for intent in intents {
            let produced = try await runner.run(intent.payload.effect, state: intent.state)
            if let produced {
                try await process(events: [produced], completing: intent.id)
            } else {
                try await journal.markCompleted(intentID: intent.id)
            }
        }
        return state
    }

    @discardableResult
    public func resumePendingEffects() async throws -> EncounterState {
        while !pendingEffects.isEmpty {
            let pending = pendingEffects[0]
            do {
                let produced = try await runner.run(pending.effect, state: pending.state)
                pendingEffects.removeFirst()
                if let produced {
                    try await process(events: [produced])
                }
            } catch {
                throw error
            }
        }
        return state
    }

    private func process(
        events initialEvents: [SimulationEvent],
        completing parentIntentID: UUID? = nil
    ) async throws {
        var pendingEvents = initialEvents
        var completionID = parentIntentID

        while !pendingEvents.isEmpty {
            let current = pendingEvents.removeFirst()
            let reduction = LiveStateReducer.reduce(state: state, event: current)

            guard let eventRecord = reduction.effects.compactMap({ effect -> EventRecord? in
                if case let .persistEvent(record) = effect { return record }
                return nil
            }).first else {
                preconditionFailure("Every reduction must emit exactly one EventRecord")
            }

            let postCommitEffects = reduction.effects.filter {
                if case .persistEvent = $0 { return false }
                return true
            }

            if let journal {
                let intents = DurableEffectPlanner.intents(
                    effects: postCommitEffects,
                    state: reduction.state
                )
                try await journal.commit(
                    event: eventRecord,
                    intents: intents,
                    completing: completionID
                )
                completionID = nil
                state = reduction.state

                for intent in intents {
                    let produced = try await runner.run(intent.payload.effect, state: intent.state)
                    if let produced {
                        try await process(events: [produced], completing: intent.id)
                    } else {
                        try await journal.markCompleted(intentID: intent.id)
                    }
                }

                for effect in postCommitEffects {
                    guard DurableEffectPayload(effect) == nil else { continue }
                    _ = try await runner.run(effect, state: state)
                }

                continue
            }

            _ = try await runner.run(.persistEvent(eventRecord), state: reduction.state)
            state = reduction.state

            for (index, effect) in postCommitEffects.enumerated() {
                let effectState = state
                let produced: SimulationEvent?
                do {
                    produced = try await runner.run(effect, state: effectState)
                } catch {
                    pendingEffects.append(contentsOf: postCommitEffects[index...].map {
                        PendingEffect(effect: $0, state: effectState)
                    })
                    throw error
                }

                if let produced {
                    try await process(events: [produced])
                }
            }
        }
    }
}


/// Reconstructs durable work after a process restart using the persisted event
/// stream as the source of truth. Service effects are considered completed only
/// when their typed result event is present later in the stream. Checkpoint
/// persistence is intentionally retryable/idempotent. Presentation effects are
/// ephemeral UI work and are not restored after relaunch.
public enum EffectRecovery {
    public static func pending(
        initial: EncounterState,
        records: [EventRecord]
    ) throws -> [PendingEffect] {
        let ordered = records.sorted { $0.sequence < $1.sequence }
        var replayState = initial
        var outstanding: [PendingEffect] = []

        for record in ordered {
            if let index = outstanding.firstIndex(where: { completes($0.effect, with: record.event) }) {
                outstanding.remove(at: index)
            }

            let reduction = LiveStateReducer.reduce(state: replayState, event: record.event)
            replayState = reduction.state

            for effect in reduction.effects where isRecoverable(effect) {
                outstanding.append(PendingEffect(effect: effect, state: replayState))
            }
        }

        return outstanding
    }

    private static func isRecoverable(_ effect: SimulationEffect) -> Bool {
        switch effect {
        case .evaluateAnswer, .requestCounterpartAction, .persistCheckpoint, .dispatchEvent:
            return true
        case .persistEvent, .presentMoment, .presentSurprise:
            return false
        }
    }

    private static func completes(_ effect: SimulationEffect, with event: SimulationEvent) -> Bool {
        switch (effect, event) {
        case let (.evaluateAnswer(expectedTurnID, _), .answerEvaluated(actualTurnID, _)):
            return expectedTurnID == actualTurnID
        case (.requestCounterpartAction, .counterpartResponded):
            return true
        case let (.dispatchEvent(expected), actual):
            return expected == actual
        default:
            return false
        }
    }
}
