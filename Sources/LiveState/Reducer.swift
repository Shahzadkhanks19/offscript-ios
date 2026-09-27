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
            encounterID: state.id,
            branchID: state.activeBranchID,
            sequence: next.sequence,
            timestamp: Determinism.timestamp(sequence: next.sequence),
            event: event
        ))

        switch event {
        case .preparationStarted:
            if LifecyclePolicy.canTransition(from: next.lifecycle, to: .preparing) { next.lifecycle = .preparing }
            return .init(state: next, effects: [record])

        case .preparationCompleted:
            guard LifecyclePolicy.canTransition(from: next.lifecycle, to: .ready) else {
                return .init(state: next, effects: [record])
            }
            if let guardrailEvent = GuardrailPolicy.event(for: next) {
                return .init(state: next, effects: [record, .dispatchEvent(guardrailEvent)])
            }
            next.lifecycle = .ready
            return .init(state: next, effects: [record])

        case .encounterStarting:
            if LifecyclePolicy.canTransition(from: next.lifecycle, to: .starting) { next.lifecycle = .starting }
            return .init(state: next, effects: [record])

        case .encounterStarted:
            guard LifecyclePolicy.canTransition(from: next.lifecycle, to: .active) else { return .init(state: next, effects: [record]) }
            next.lifecycle = .active
            next.conversation.turnState = .counterpartThinking
            return .init(state: next, effects: [record, .requestCounterpartAction(.askOpeningQuestion)])

        case .userSpeechStarted:
            guard next.lifecycle == .active else { return .init(state: next, effects: [record]) }
            next.conversation.turnState = .userSpeaking
            return .init(state: next, effects: [record])

        case .userSpeechEnded:
            guard next.lifecycle == .active else { return .init(state: next, effects: [record]) }
            if next.conversation.turnState == .userSpeaking || next.conversation.turnState == .overlap {
                next.conversation.turnState = .idle
            }
            return .init(state: next, effects: [record])

        case .userSilenceStarted:
            guard next.lifecycle == .active else { return .init(state: next, effects: [record]) }
            next.conversation.turnState = .silence
            return .init(state: next, effects: [record])

        case .counterpartInterrupted:
            guard next.lifecycle == .active else { return .init(state: next, effects: [record]) }
            if next.conversation.turnState == .counterpartSpeaking {
                next.conversation.turnState = .overlap
                next.user.interruptions += 1
            }
            return .init(state: next, effects: [record])

        case .counterpartSpeechStarted:
            guard next.lifecycle == .active else { return .init(state: next, effects: [record]) }
            next.conversation.turnState = .counterpartSpeaking
            return .init(state: next, effects: [record])

        case .counterpartSpeechFinished:
            guard next.lifecycle == .active else { return .init(state: next, effects: [record]) }
            if next.conversation.turnState == .counterpartSpeaking {
                next.conversation.turnState = .idle
            }
            return .init(state: next, effects: [record])

        case .counterpartSpeechCancelled:
            guard next.lifecycle == .active else { return .init(state: next, effects: [record]) }
            if next.conversation.turnState == .counterpartSpeaking || next.conversation.turnState == .overlap {
                next.conversation.turnState = .idle
            }
            return .init(state: next, effects: [record])

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
                next.surpriseCount += 1
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
                branchID: Determinism.branchID(
                    encounterID: state.id,
                    parentBranchID: checkpoint.parentBranchID,
                    checkpointID: checkpoint.id,
                    sequence: next.sequence
                )
            )
            restored.sequence = next.sequence
            restored.branchLineage.register(branchID: restored.activeBranchID, parentCheckpointID: checkpoint.id)
            return .init(state: restored, effects: [record])

        case let .pressureAdjusted(delta):
            next.pressure.adaptiveModifier = min(max(next.pressure.adaptiveModifier + delta, -1), 1)
            return .init(state: next, effects: [record])

        case let .surpriseTriggered(surprise):
            if next.pendingSurprise == nil && next.surpriseCount < next.surpriseBudget {
                next.pendingSurprise = surprise
                next.lastSurpriseTurn = next.user.totalTurns
                next.surpriseCount += 1
                return .init(state: next, effects: [record, .presentSurprise(surprise)])
            }
            return .init(state: next, effects: [record])

        case let .surpriseCleared(id):
            if next.pendingSurprise?.id == id {
                next.pendingSurprise = nil
            }
            return .init(state: next, effects: [record])

        case let .observableSignalsUpdated(signals):
            next.user.latestSignals = signals
            next.user.interruptions += signals.reduce(0) { count, signal in
                guard case let .turn(observation) = signal, observation.interruptedCounterpart else { return count }
                return count + 1
            }
            return .init(state: next, effects: [record])

        case let .guardrailActionChanged(action):
            next.guardrails.action = action
            return .init(state: next, effects: [record])

        case .encounterPaused:
            guard LifecyclePolicy.canTransition(from: next.lifecycle, to: .paused) else { return .init(state: next, effects: [record]) }
            next.lifecycle = .paused; next.conversation.turnState = .paused
            return .init(state: next, effects: [record])

        case .encounterResumed:
            guard LifecyclePolicy.canTransition(from: next.lifecycle, to: .active) else { return .init(state: next, effects: [record]) }
            next.lifecycle = .active; next.conversation.turnState = .idle
            return .init(state: next, effects: [record])

        case .encounterEnding:
            if LifecyclePolicy.canTransition(from: next.lifecycle, to: .ending) { next.lifecycle = .ending }
            return .init(state: next, effects: [record])

        case .encounterProcessing:
            if LifecyclePolicy.canTransition(from: next.lifecycle, to: .processing) { next.lifecycle = .processing }
            return .init(state: next, effects: [record])

        case .encounterCompleted:
            if LifecyclePolicy.canTransition(from: next.lifecycle, to: .completed) {
                next.lifecycle = .completed
                next.conversation.turnState = .idle
            }
            return .init(state: next, effects: [record])

        case .reviewStarted:
            if LifecyclePolicy.canTransition(from: next.lifecycle, to: .reviewing) { next.lifecycle = .reviewing }
            return .init(state: next, effects: [record])

        case .retryStarted:
            if LifecyclePolicy.canTransition(from: next.lifecycle, to: .retrying) { next.lifecycle = .retrying }
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
