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

    public init(state: EncounterState = .init(), runner: EffectRunner) {
        self.state = state
        self.runner = runner
    }

    @discardableResult
    public func send(_ event: SimulationEvent) async throws -> EncounterState {
        try await resumePendingEffects()
        try await process(events: [event])
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

    private func process(events initialEvents: [SimulationEvent]) async throws {
        var pendingEvents = initialEvents

        while !pendingEvents.isEmpty {
            let current = pendingEvents.removeFirst()
            let reduction = LiveStateReducer.reduce(state: state, event: current)

            let persistenceEffects = reduction.effects.filter {
                if case .persistEvent = $0 { return true }
                return false
            }
            let postCommitEffects = reduction.effects.filter {
                if case .persistEvent = $0 { return false }
                return true
            }

            for effect in persistenceEffects {
                _ = try await runner.run(effect, state: reduction.state)
            }

            state = reduction.state

            for (index, effect) in postCommitEffects.enumerated() {
                do {
                    if let produced = try await runner.run(effect, state: state) {
                        pendingEvents.append(produced)
                    }
                } catch {
                    pendingEffects.append(contentsOf: postCommitEffects[index...].map {
                        PendingEffect(effect: $0, state: state)
                    })
                    throw error
                }
            }
        }
    }
}
