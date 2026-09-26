import Foundation

/// Coordinates the pure reducer with external services. The runtime owns no
/// simulation rules: every state change still enters through LiveStateReducer.
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
            state = reduction.state

            for effect in reduction.effects {
                if let produced = try await runner.run(effect, state: state) {
                    pending.append(produced)
                }
            }
        }

        return state
    }
}
