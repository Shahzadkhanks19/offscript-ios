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
        let eventID = Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "event")
        let record = SimulationEffect.persistEvent(.init(
            id: eventID,
            sequence: next.sequence,
            timestamp: Determinism.timestamp(sequence: next.sequence),
            event: event
        ))

        switch event {
        case .encounterStarted:
            next.lifecycle = .active
            next.conversation.turnState = .counterpartThinking
            return .init(state: next, effects: [record, .requestCounterpartAction(.askOpeningQuestion)])

        case let .userSubmitted(text):
            let turn = ConversationTurn(
                id: Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "user-turn"),
                speaker: .user,
                text: text,
                createdAt: Determinism.timestamp(sequence: next.sequence)
            )
            next.conversation.turns.append(turn)
            next.conversation.turnState = .counterpartThinking
            updateObservableStats(with: turn, state: &next)
            return .init(state: next, effects: [record, .evaluateAnswer(turnID: turn.id, text: text)])

        case let .counterpartResponded(text):
            next.conversation.turns.append(.init(
                id: Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "counterpart-turn"),
                speaker: .counterpart,
                text: text,
                createdAt: Determinism.timestamp(sequence: next.sequence)
            ))
            next.conversation.turnState = .idle
            return .init(state: next, effects: [record])

        case let .answerEvaluated(turnID, evaluation):
            apply(evaluation.objectiveEvaluations, turnID: turnID, state: &next)
            CounterpartMemory.merge(
                CounterpartMemory.derive(turnID: turnID, evaluation: evaluation) { index in
                    Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "memory", index: index)
                },
                into: &next.counterpart.memory
            )
            CounterpartDynamics.apply(CounterpartDynamics.delta(for: evaluation), to: &next.counterpart)
            next.pressure.adaptiveModifier = min(max(next.pressure.adaptiveModifier + PressureEngine.adaptiveDelta(for: evaluation), -1), 1)
            var effects: [SimulationEffect] = [record]
            let detectedMoment = MomentEngine.detect(
                turnID: turnID,
                evaluation: evaluation,
                id: Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "moment")
            )
            if let moment = detectedMoment {
                next.moments.append(moment)
                effects.append(.presentMoment(moment))
            }
            if let surprise = SurpriseEngine.next(
                for: next,
                id: Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "surprise")
            ) {
                next.pendingSurprise = surprise
                next.lastSurpriseTurn = next.user.totalTurns
                effects.append(.presentSurprise(surprise))
            }
            if CheckpointPolicy.reason(state: next, evaluation: evaluation, moment: detectedMoment) != nil {
                effects.append(.persistCheckpoint(Branching.checkpoint(
                    next,
                    id: Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "checkpoint")
                )))
            }
            effects.append(.requestCounterpartAction(PolicyEngine.nextAction(for: next, evaluation: evaluation)))
            return .init(state: next, effects: effects)

        case let .checkpointRestored(checkpoint):
            var restored = Branching.restore(
                checkpoint,
                branchID: Determinism.id(encounterID: state.id, sequence: next.sequence, domain: "branch")
            )
            restored.sequence = next.sequence
            return .init(state: restored, effects: [record])

        case let .pressureAdjusted(delta):
            next.pressure.adaptiveModifier = min(max(next.pressure.adaptiveModifier + delta, -1), 1)
            return .init(state: next, effects: [record])

        case let .surpriseTriggered(surprise):
            next.pendingSurprise = surprise
            return .init(state: next, effects: [record, .presentSurprise(surprise)])

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
        for (evaluationIndex, evaluation) in evaluations.enumerated() {
            guard let index = state.objectives.firstIndex(where: { $0.id == evaluation.objectiveID }) else { continue }
            state.objectives[index].status = evaluation.status
            state.objectives[index].evidence.append(.init(
                id: Determinism.id(encounterID: state.id, sequence: state.sequence, domain: "evidence", index: evaluationIndex),
                turnID: turnID,
                reason: evaluation.reason,
                confidence: evaluation.confidence
            ))
        }
    }

    private static func updateObservableStats(with turn: ConversationTurn, state: inout EncounterState) {
        let previous = Double(state.user.totalTurns)
        state.user.totalTurns += 1
        state.user.averageTurnCharacterCount = ((state.user.averageTurnCharacterCount * previous) + Double(turn.text.count)) / Double(state.user.totalTurns)
    }

}
