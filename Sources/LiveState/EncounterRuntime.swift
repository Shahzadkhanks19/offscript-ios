import Foundation

/// Coordinates the pure reducer with external services. The runtime owns no
/// simulation rules: every state change still enters through LiveStateReducer.
///
/// Durability rule: an event-derived state is committed in memory only after
/// its EventRecord has been saved successfully. Non-persistence effects run
/// only after that commit, so failed persistence cannot leak external work
/// from an uncommitted transition.
public actor EncounterRuntime {
    public private(set) var state: EncounterState
    private let runner: EffectRunner

    public init(state: EncounterState = .init(), runner: EffectRunner) {
        self.state = state
        self.runner = runner
    }

    @discardableResult
    public func send(_ event: SimulationEvent) async throws -> EncounterState {
        var pending: [SimulationEvent] = [event]

        while !pending.isEmpty {
            let current = pending.removeFirst()
            let reduction = LiveStateReducer.reduce(state: state, event: current)

            let persistenceEffects = reduction.effects.filter {
                if case .persistEvent = $0 { return true }
                return false
            }
            let postCommitEffects = reduction.effects.filter {
                if case .persistEvent = $0 { return false }
                return true
            }

            // Persist first. If this throws, authoritative in-memory state is
            // unchanged and no service/checkpoint/presentation effect runs.
            for effect in persistenceEffects {
                _ = try await runner.run(effect, state: reduction.state)
            }

            state = reduction.state

            for effect in postCommitEffects {
                if let produced = try await runner.run(effect, state: state) {
                    pending.append(produced)
                }
            }
        }

        return state
    }
}
