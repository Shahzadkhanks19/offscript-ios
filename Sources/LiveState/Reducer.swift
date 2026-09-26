import Foundation

public struct Reduction: Sendable {
    public var state: EncounterState
    public var effects: [SimulationEffect]
    public init(state: EncounterState, effects: [SimulationEffect] = []) { self.state = state; self.effects = effects }
}

public enum LiveStateReducer {
    public static func reduce(state: EncounterState, event: SimulationEvent) -> Reduction {
        var next = state
        next.sequence += 1
        let record = SimulationEffect.persistEvent(.init(sequence: next.sequence, kind: eventKind(event)))

        switch event {
        case .encounterStarted:
            next.lifecycle = .active
            next.conversation.turnState = .counterpartThinking
            return .init(state: next, effects: [record, .requestCounterpartAction(.askOpeningQuestion)])

        case let .userSubmitted(text):
            let turn = ConversationTurn(speaker: .user, text: text)
            next.conversation.turns.append(turn)
            next.conversation.turnState = .counterpartThinking
            updateObservableStats(with: turn, state: &next)
            return .init(state: next, effects: [record, .evaluateAnswer(turnID: turn.id, text: text)])

        case let .counterpartResponded(text):
            next.conversation.turns.append(.init(speaker: .counterpart, text: text))
            next.conversation.turnState = .idle
            return .init(state: next, effects: [record])

        case let .answerEvaluated(turnID, evaluation):
            apply(evaluation.objectiveEvaluations, turnID: turnID, state: &next)
            let checkpoint = Branching.checkpoint(next)
            let action = PolicyEngine.nextAction(for: next, evaluation: evaluation)
            return .init(state: next, effects: [record, .persistCheckpoint(checkpoint), .requestCounterpartAction(action)])

        case let .checkpointRestored(checkpoint):
            var restored = Branching.restore(checkpoint)
            restored.sequence = next.sequence
            return .init(state: restored, effects: [record])

        case let .pressureAdjusted(delta):
            next.pressure.adaptiveModifier = min(max(next.pressure.adaptiveModifier + delta, -1), 1)
            return .init(state: next, effects: [record])

        case .encounterPaused:
            next.lifecycle = .paused; next.conversation.turnState = .paused
            return .init(state: next, effects: [record])

        case .encounterResumed:
            next.lifecycle = .active; next.conversation.turnState = .idle
            return .init(state: next, effects: [record])

        case .encounterCompleted:
            next.lifecycle = .completed; next.conversation.turnState = .idle
            return .init(state: next, effects: [record])
        }
    }

    private static func apply(_ evaluations: [ObjectiveEvaluation], turnID: UUID, state: inout EncounterState) {
        for evaluation in evaluations {
            guard let index = state.objectives.firstIndex(where: { $0.id == evaluation.objectiveID }) else { continue }
            state.objectives[index].status = evaluation.status
            state.objectives[index].evidence.append(.init(turnID: turnID, reason: evaluation.reason, confidence: evaluation.confidence))
        }
    }

    private static func updateObservableStats(with turn: ConversationTurn, state: inout EncounterState) {
        let previous = Double(state.user.totalTurns)
        state.user.totalTurns += 1
        state.user.averageTurnCharacterCount = ((state.user.averageTurnCharacterCount * previous) + Double(turn.text.count)) / Double(state.user.totalTurns)
    }

    private static func eventKind(_ event: SimulationEvent) -> String {
        switch event {
        case .encounterStarted: "encounterStarted"
        case .userSubmitted: "userSubmitted"
        case .counterpartResponded: "counterpartResponded"
        case .answerEvaluated: "answerEvaluated"
        case .checkpointRestored: "checkpointRestored"
        case .pressureAdjusted: "pressureAdjusted"
        case .encounterPaused: "encounterPaused"
        case .encounterResumed: "encounterResumed"
        case .encounterCompleted: "encounterCompleted"
        }
    }
}
