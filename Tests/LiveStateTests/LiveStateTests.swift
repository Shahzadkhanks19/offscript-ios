import XCTest
@testable import LiveState

final class LiveStateTests: XCTestCase {
    func testStartActivatesEncounterAndRequestsOpeningQuestion() {
        let starting = EncounterState(lifecycle: .starting)
        let result = LiveStateReducer.reduce(state: starting, event: .encounterStarted)
        XCTAssertEqual(result.state.lifecycle, .active)
        XCTAssertEqual(result.state.conversation.turnState, .counterpartThinking)
        XCTAssertTrue(result.effects.contains(.requestCounterpartAction(.askOpeningQuestion)))
        XCTAssertEqual(result.state.sequence, 1)
    }

    func testEncounterCannotSkipPreparationAndStartingLifecycle() {
        let result = LiveStateReducer.reduce(state: .init(), event: .encounterStarted)
        XCTAssertEqual(result.state.lifecycle, .created)
        XCTAssertEqual(result.state.conversation.turnState, .idle)
        XCTAssertFalse(result.effects.contains(.requestCounterpartAction(.askOpeningQuestion)))
        XCTAssertEqual(result.state.sequence, 1)
    }

    func testUserSubmissionCreatesTurnAndEvaluationEffect() {
        let result = LiveStateReducer.reduce(state: .init(lifecycle: .active), event: .userSubmitted("I chose Next.js for SSR."))
        XCTAssertEqual(result.state.conversation.turns.count, 1)
        XCTAssertEqual(result.state.user.totalTurns, 1)
        XCTAssertGreaterThan(result.state.user.averageTurnCharacterCount, 0)
        XCTAssertTrue(result.effects.contains { if case .evaluateAnswer = $0 { true } else { false } })
    }

    func testObjectiveEvaluationRequiresEvidence() {
        var state = EncounterState(lifecycle: .active)
        let submitted = LiveStateReducer.reduce(state: state, event: .userSubmitted("SSR helped SEO, but increased server complexity."))
        state = submitted.state
        guard case let .evaluateAnswer(turnID, _) = submitted.effects.first(where: { if case .evaluateAnswer = $0 { true } else { false } }) else {
            return XCTFail("Expected evaluation effect")
        }
        let evaluation = AnswerEvaluation(
            answeredQuestion: true,
            relevance: 0.9,
            specificity: 0.8,
            objectiveEvaluations: [
                .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explains SSR motivation.", confidence: 0.94),
                .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Names server complexity tradeoff.", confidence: 0.91)
            ]
        )
        let result = LiveStateReducer.reduce(state: state, event: .answerEvaluated(turnID: turnID, evaluation))
        let tradeoff = result.state.objectives.first { $0.id == "tradeoffAwareness" }
        XCTAssertEqual(tradeoff?.status, .satisfied)
        XCTAssertEqual(tradeoff?.evidence.first?.turnID, turnID)
        XCTAssertFalse(tradeoff?.evidence.first?.reason.isEmpty ?? true)
    }

    func testMissingTradeoffIsChallenged() {
        var state = EncounterState(lifecycle: .active)
        let submitted = LiveStateReducer.reduce(state: state, event: .userSubmitted("Next.js improved discoverability."))
        state = submitted.state
        guard case let .evaluateAnswer(turnID, _) = submitted.effects.first(where: { if case .evaluateAnswer = $0 { true } else { false } }) else {
            return XCTFail("Expected evaluation effect")
        }
        let evaluation = AnswerEvaluation(
            answeredQuestion: true, relevance: 0.9, specificity: 0.8,
            objectiveEvaluations: [.init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explains motivation.", confidence: 0.9)]
        )
        let result = LiveStateReducer.reduce(state: state, event: .answerEvaluated(turnID: turnID, evaluation))
        XCTAssertTrue(result.effects.contains(.requestCounterpartAction(.challengeTradeoff)))
    }

    func testLowSpecificityRequestsExampleBeforeTradeoffChallenge() {
        let state = EncounterState(lifecycle: .active)
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.8, specificity: 0.2)
        XCTAssertEqual(PolicyEngine.nextAction(for: state, evaluation: evaluation), .askForSpecificExample)
    }

    func testPressureIsClamped() {
        var state = EncounterState(lifecycle: .active)
        state = LiveStateReducer.reduce(state: state, event: .pressureAdjusted(0.8)).state
        state = LiveStateReducer.reduce(state: state, event: .pressureAdjusted(0.8)).state
        XCTAssertEqual(state.pressure.adaptiveModifier, 1)
        XCTAssertEqual(state.pressure.effective, 1)
    }

    func testPauseResumeLifecycle() {
        var state = EncounterState(lifecycle: .active)
        state = LiveStateReducer.reduce(state: state, event: .encounterPaused).state
        XCTAssertEqual(state.lifecycle, .paused)
        XCTAssertEqual(state.conversation.turnState, .paused)
        state = LiveStateReducer.reduce(state: state, event: .encounterResumed).state
        XCTAssertEqual(state.lifecycle, .active)
        XCTAssertEqual(state.conversation.turnState, .idle)
    }

    func testRestorePreservesHistoryAndCreatesNewBranch() {
        var state = EncounterState(lifecycle: .active)
        state.conversation.turns.append(.init(speaker: .counterpart, text: "Why didn't you use Redux?"))
        let checkpoint = Branching.checkpoint(state)
        let originalBranch = state.activeBranchID
        let restored = Branching.restore(checkpoint)
        XCTAssertEqual(restored.conversation.turns, state.conversation.turns)
        XCTAssertNotEqual(restored.activeBranchID, originalBranch)
        XCTAssertEqual(checkpoint.parentBranchID, originalBranch)
    }

    func testEveryReductionAdvancesSequenceAndEmitsEventRecord() {
        let result = LiveStateReducer.reduce(state: .init(), event: .encounterStarted)
        XCTAssertEqual(result.state.sequence, 1)
        XCTAssertTrue(result.effects.contains { if case .persistEvent = $0 { true } else { false } })
    }
    func testStrongAnswerChangesCounterpartSimulationState() {
        var state = EncounterState(lifecycle: .active)
        let initialSkepticism = state.counterpart.skepticism
        let submitted = LiveStateReducer.reduce(state: state, event: .userSubmitted("We used SSR for discoverability and accepted extra server complexity."))
        state = submitted.state
        guard case let .evaluateAnswer(turnID, _) = submitted.effects.first(where: { if case .evaluateAnswer = $0 { true } else { false } }) else { return XCTFail() }
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.95, specificity: 0.9)
        let result = LiveStateReducer.reduce(state: state, event: .answerEvaluated(turnID: turnID, evaluation))
        XCTAssertLessThan(result.state.counterpart.skepticism, initialSkepticism)
        XCTAssertGreaterThan(result.state.counterpart.engagement, 0.65)
    }

    func testMomentEngineMarksSpecificMultiObjectiveAnswerStrong() {
        let turnID = UUID()
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.95, specificity: 0.9, objectiveEvaluations: [
            .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Clear reason", confidence: 0.9),
            .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Clear tradeoff", confidence: 0.9)
        ])
        XCTAssertEqual(MomentEngine.detect(turnID: turnID, evaluation: evaluation)?.kind, .strong)
    }

    func testSurpriseTargetsUnresolvedObjectiveAfterEnoughTurns() {
        var state = EncounterState(lifecycle: .active)
        state.pressure.base = 0.7
        state.user.totalTurns = 2
        let surprise = SurpriseEngine.next(for: state)
        XCTAssertNotNil(surprise)
        XCTAssertEqual(surprise?.targetObjectiveID, "architectureReasoning")
    }

    func testReplayProducesEquivalentCoreState() {
        let initial = EncounterState()
        let events = [
            RecordedEvent(sequence: 1, event: .encounterStarted),
            RecordedEvent(sequence: 2, event: .userSubmitted("A concrete answer"))
        ]
        let replayed = ReplayEngine.replay(initial: initial, events: events)
        var manual = LiveStateReducer.reduce(state: initial, event: .encounterStarted).state
        manual = LiveStateReducer.reduce(state: manual, event: .userSubmitted("A concrete answer")).state
        XCTAssertEqual(replayed.lifecycle, manual.lifecycle)
        XCTAssertEqual(replayed.sequence, manual.sequence)
        XCTAssertEqual(replayed.conversation.turns.map(\.text), manual.conversation.turns.map(\.text))
    }

    func testBranchComparisonReportsObjectiveChange() {
        let original = EncounterState(lifecycle: .active)
        let checkpoint = Branching.checkpoint(original)
        var retry = Branching.restore(checkpoint)
        retry.objectives[0].status = .satisfied
        let comparison = BranchComparator.compare(original: original, retry: retry)
        XCTAssertNotEqual(comparison.originalBranchID, comparison.retryBranchID)
        XCTAssertEqual(comparison.objectiveStatusChanges["architectureReasoning"], .satisfied)
    }

    func testObjectiveGraphRespectsDependencies() {
        var state = EncounterState(lifecycle: .active)
        XCTAssertEqual(ObjectiveGraph.nextEligible(in: state)?.id, "architectureReasoning")
        state.objectives[0].status = .satisfied
        XCTAssertEqual(ObjectiveGraph.nextEligible(in: state)?.id, "tradeoffAwareness")
    }

    func testCounterpartMemoryKeepsHigherImportanceEvidence() {
        let turnA = UUID(), turnB = UUID()
        var memory = [MemoryItem(sourceTurnID: turnA, topic: "architectureReasoning", summary: "weak", importance: 0.65)]
        CounterpartMemory.merge([.init(sourceTurnID: turnB, topic: "architectureReasoning", summary: "strong", importance: 0.95)], into: &memory)
        XCTAssertEqual(memory.count, 1)
        XCTAssertEqual(memory.first?.summary, "strong")
        XCTAssertEqual(memory.first?.sourceTurnID, turnB)
    }

    func testSurpriseCooldownPreventsBackToBackSurprises() {
        var state = EncounterState(lifecycle: .active)
        state.pressure.base = 0.8
        state.user.totalTurns = 3
        state.lastSurpriseTurn = 2
        XCTAssertNil(SurpriseEngine.next(for: state))
        state.user.totalTurns = 4
        XCTAssertNotNil(SurpriseEngine.next(for: state))
    }

    func testCheckpointPolicyDoesNotCheckpointEveryOrdinaryTurn() {
        let state = EncounterState(lifecycle: .active)
        let ordinary = AnswerEvaluation(answeredQuestion: true, relevance: 0.8, specificity: 0.65)
        XCTAssertNil(CheckpointPolicy.reason(state: state, evaluation: ordinary, moment: nil))
    }

    func testCheckpointPolicyCapturesObjectiveProgress() {
        let state = EncounterState(lifecycle: .active)
        let evaluation = AnswerEvaluation(answeredQuestion: true, relevance: 0.9, specificity: 0.8, objectiveEvaluations: [
            .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "clear", confidence: 0.9)
        ])
        XCTAssertEqual(CheckpointPolicy.reason(state: state, evaluation: evaluation, moment: nil), .objectiveProgress)
    }

    func testMultiTurnInterviewAdaptsPolicyAcrossObjectives() {
        var state = LiveStateReducer.reduce(state: .init(), event: .encounterStarted).state

        let first = EncounterFixture.apply(.init(
            text: "We chose Next.js because SSR helped discoverability, but it increased server complexity.",
            evaluation: .init(answeredQuestion: true, relevance: 0.95, specificity: 0.9, objectiveEvaluations: [
                .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explained SSR motivation.", confidence: 0.95),
                .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Named server complexity.", confidence: 0.92)
            ])
        ), to: state)
        state = first.state
        XCTAssertTrue(first.effects.contains(.requestCounterpartAction(.deepenFollowUp)))

        state = LiveStateReducer.reduce(state: state, event: .counterpartResponded("Tell me about a production issue you handled.")).state

        let second = EncounterFixture.apply(.init(
            text: "We had a cache invalidation issue after deployment and fixed the revalidation strategy.",
            evaluation: .init(answeredQuestion: true, relevance: 0.96, specificity: 0.88, objectiveEvaluations: [
                .init(objectiveID: "productionExperience", status: .satisfied, reason: "Gave a concrete production incident and response.", confidence: 0.94)
            ])
        ), to: state)
        state = second.state

        XCTAssertEqual(state.objectives.first(where: { $0.id == "productionExperience" })?.status, .satisfied)
        XCTAssertEqual(state.counterpart.memory.count, 3)
        XCTAssertTrue(second.effects.contains(.requestCounterpartAction(.acknowledgeAndContinue)))
        XCTAssertEqual(state.user.totalTurns, 2)
    }

    func testTakeAnotherCreatesAlternateBranchAndImprovesObjective() {
        var state = LiveStateReducer.reduce(state: .init(), event: .encounterStarted).state

        let weak = EncounterFixture.apply(.init(
            text: "Next.js is fast and popular.",
            evaluation: .init(answeredQuestion: true, relevance: 0.7, specificity: 0.3)
        ), to: state)
        state = weak.state

        // Create the retry point explicitly for the fixture: production uses the nearest
        // meaningful checkpoint selected by CheckpointPolicy.
        let retryPoint = Branching.checkpoint(state)
        let original = state
        let session = RetryEngine.begin(from: retryPoint, original: original)
        XCTAssertNotEqual(session.original.activeBranchID, session.retry.activeBranchID)

        let improved = EncounterFixture.apply(.init(
            text: "We chose Next.js for SSR on discoverable pages; the tradeoff was extra server complexity.",
            evaluation: .init(answeredQuestion: true, relevance: 0.96, specificity: 0.9, objectiveEvaluations: [
                .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explained why SSR was needed.", confidence: 0.96),
                .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Named the server-complexity tradeoff.", confidence: 0.93)
            ])
        ), to: session.retry)

        let comparison = RetryEngine.compare(session, retryState: improved.state)
        XCTAssertEqual(comparison.objectiveStatusChanges["architectureReasoning"], .satisfied)
        XCTAssertEqual(comparison.objectiveStatusChanges["tradeoffAwareness"], .satisfied)
        XCTAssertEqual(improved.state.moments.last?.kind, .strong)
    }

    func testRetryPreservesPreCheckpointHistory() {
        var state = EncounterState(lifecycle: .active)
        state = LiveStateReducer.reduce(state: state, event: .counterpartResponded("Why Next.js?")).state
        let checkpoint = Branching.checkpoint(state)
        let retry = RetryEngine.begin(from: checkpoint, original: state).retry
        XCTAssertEqual(retry.conversation.turns.map(\.text), ["Why Next.js?"])
        XCTAssertNotEqual(retry.activeBranchID, state.activeBranchID)
    }

    func testReplayReconstructsExactStateIncludingGeneratedIdentity() {
        let initial = EncounterState(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            activeBranchID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let events: [RecordedEvent] = [
            .init(sequence: 1, event: .encounterStarted),
            .init(sequence: 2, event: .counterpartResponded("Why did you choose Next.js?")),
            .init(sequence: 3, event: .userSubmitted("SSR improved discoverability."))
        ]

        let first = ReplayEngine.replay(initial: initial, events: events)
        let second = ReplayEngine.replay(initial: initial, events: events)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.conversation.turns, second.conversation.turns)
    }

    func testPersistedEventEnvelopeCanDriveReplay() {
        let initial = EncounterState(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            activeBranchID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let started = LiveStateReducer.reduce(state: initial, event: .encounterStarted)
        let submitted = LiveStateReducer.reduce(state: started.state, event: .userSubmitted("A persisted answer"))

        let records = (started.effects + submitted.effects).compactMap { effect -> EventRecord? in
            if case let .persistEvent(record) = effect { return record }
            return nil
        }

        let replayed = ReplayEngine.replay(initial: initial, records: records)
        XCTAssertEqual(replayed, submitted.state)
        XCTAssertEqual(records.map(\.schemaVersion), [2, 2])
        XCTAssertEqual(records.map(\.kind), ["encounterStarted", "userSubmitted"])
    }

    func testDeterministicReductionProducesSameEventEnvelope() {
        let state = EncounterState(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            activeBranchID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let first = LiveStateReducer.reduce(state: state, event: .userSubmitted("Same input"))
        let second = LiveStateReducer.reduce(state: state, event: .userSubmitted("Same input"))
        XCTAssertEqual(first.state, second.state)
        XCTAssertEqual(first.effects, second.effects)
    }

    func testEventEnvelopeJSONRoundTripPreservesPayload() throws {
        let encounterID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let record = EventRecord(
            id: Determinism.id(encounterID: encounterID, sequence: 7, domain: "event"),
            sequence: 7,
            timestamp: Determinism.timestamp(sequence: 7),
            event: .userSubmitted("Round-trip this exact answer")
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(EventRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.kind, "userSubmitted")
    }

    func testScenarioKnowledgeDoesNotExposePrivateUserContextToCounterpart() {
        let knowledge = ScenarioKnowledge(
            counterpartVisible: [.init(id: "role", value: "Senior React Developer")],
            privateUserContext: [.init(id: "weakness", value: "Needs practice with system design")]
        )
        XCTAssertEqual(knowledge.counterpartContext.map(\.id), ["role"])
        XCTAssertFalse(knowledge.counterpartContext.contains { $0.id == "weakness" })
    }

    func testFullEncounterLifecycleProgression() {
        var state = EncounterState()
        state = LiveStateReducer.reduce(state: state, event: .preparationStarted).state
        XCTAssertEqual(state.lifecycle, .preparing)
        state = LiveStateReducer.reduce(state: state, event: .preparationCompleted).state
        XCTAssertEqual(state.lifecycle, .ready)
        state = LiveStateReducer.reduce(state: state, event: .encounterStarting).state
        XCTAssertEqual(state.lifecycle, .starting)
        state = LiveStateReducer.reduce(state: state, event: .encounterStarted).state
        XCTAssertEqual(state.lifecycle, .active)
        state = LiveStateReducer.reduce(state: state, event: .encounterEnding).state
        XCTAssertEqual(state.lifecycle, .ending)
        state = LiveStateReducer.reduce(state: state, event: .encounterProcessing).state
        XCTAssertEqual(state.lifecycle, .processing)
        state = LiveStateReducer.reduce(state: state, event: .encounterCompleted).state
        XCTAssertEqual(state.lifecycle, .completed)
        state = LiveStateReducer.reduce(state: state, event: .reviewStarted).state
        XCTAssertEqual(state.lifecycle, .reviewing)
        state = LiveStateReducer.reduce(state: state, event: .retryStarted).state
        XCTAssertEqual(state.lifecycle, .retrying)
    }

    func testObservableSignalsRemainMeasurementsAndUpdateInterruptionCount() {
        let signals: [ObservableSignal] = [
            .speech(.init(wordsPerMinute: 142, pauseCount: 2, longestPauseSeconds: 1.4)),
            .turn(.init(interruptedCounterpart: true, wasInterrupted: false, durationSeconds: 18)),
            .visual(.init(facePresent: true, lookingAtNotes: false, framingStable: true))
        ]
        let result = LiveStateReducer.reduce(
            state: .init(lifecycle: .active),
            event: .observableSignalsUpdated(signals)
        )
        XCTAssertEqual(result.state.user.latestSignals, signals)
        XCTAssertEqual(result.state.user.interruptions, 1)
    }

    func testSignalEventSurvivesJSONPersistenceAndReplay() throws {
        let event = SimulationEvent.observableSignalsUpdated([
            .speech(.init(wordsPerMinute: 130, pauseCount: 1, longestPauseSeconds: 0.8))
        ])
        let record = EventRecord(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            sequence: 1,
            timestamp: Determinism.timestamp(sequence: 1),
            event: event
        )
        let decoded = try JSONDecoder().decode(EventRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)

        let initial = EncounterState()
        let replayed = ReplayEngine.replay(initial: initial, records: [decoded])
        XCTAssertEqual(replayed.user.latestSignals, [
            .speech(.init(wordsPerMinute: 130, pauseCount: 1, longestPauseSeconds: 0.8))
        ])
    }

    func testSurpriseBudgetAndLifecyclePreventChallengeSpam() {
        let firstID = UUID(uuidString: "99999999-9999-9999-9999-999999999991")!
        let secondID = UUID(uuidString: "99999999-9999-9999-9999-999999999992")!
        let first = Surprise(id: firstID, kind: .deeperProbe, targetObjectiveID: "architectureReasoning", reason: "First")
        let second = Surprise(id: secondID, kind: .skepticalChallenge, targetObjectiveID: "tradeoffAwareness", reason: "Second")

        var state = EncounterState(lifecycle: .active, surpriseBudget: 1)
        state = LiveStateReducer.reduce(state: state, event: .surpriseTriggered(first)).state
        XCTAssertEqual(state.pendingSurprise?.id, firstID)
        XCTAssertEqual(state.surpriseCount, 1)

        state = LiveStateReducer.reduce(state: state, event: .surpriseTriggered(second)).state
        XCTAssertEqual(state.pendingSurprise?.id, firstID)
        XCTAssertEqual(state.surpriseCount, 1)

        state = LiveStateReducer.reduce(state: state, event: .surpriseCleared(firstID)).state
        XCTAssertNil(state.pendingSurprise)
        XCTAssertNil(SurpriseEngine.next(for: state))
    }

    func testCheckpointRestoreRecordsDeterministicBranchLineage() {
        let encounterID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let originalBranch = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let checkpointID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let state = EncounterState(id: encounterID, lifecycle: .active, activeBranchID: originalBranch)
        let checkpoint = Branching.checkpoint(state, id: checkpointID)

        let restored = LiveStateReducer.reduce(state: state, event: .checkpointRestored(checkpoint)).state
        XCTAssertNotEqual(restored.activeBranchID, originalBranch)
        XCTAssertEqual(restored.branchLineage.parentCheckpointID(for: restored.activeBranchID), checkpointID)
    }

    func testSurpriseLifecycleReplaysExactly() {
        let encounterID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let surpriseID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let initial = EncounterState(id: encounterID, lifecycle: .active)
        let surprise = Surprise(id: surpriseID, kind: .deeperProbe, targetObjectiveID: "architectureReasoning", reason: "Probe")

        let events: [RecordedEvent] = [
            .init(sequence: 1, event: .surpriseTriggered(surprise)),
            .init(sequence: 2, event: .surpriseCleared(surpriseID))
        ]
        let first = ReplayEngine.replay(initial: initial, events: events)
        let second = ReplayEngine.replay(initial: initial, events: events)
        XCTAssertEqual(first, second)
        XCTAssertNil(first.pendingSurprise)
        XCTAssertEqual(first.surpriseCount, 1)
    }

    func testLifecyclePolicyRejectsInvalidJumps() {
        XCTAssertTrue(LifecyclePolicy.canTransition(from: .created, to: .preparing))
        XCTAssertTrue(LifecyclePolicy.canTransition(from: .active, to: .paused))
        XCTAssertTrue(LifecyclePolicy.canTransition(from: .reviewing, to: .retrying))
        XCTAssertFalse(LifecyclePolicy.canTransition(from: .created, to: .completed))
        XCTAssertFalse(LifecyclePolicy.canTransition(from: .ready, to: .reviewing))
    }

    func testEncounterCarriesVersionedEngineMetadata() throws {
        let state = EncounterState()
        XCTAssertEqual(state.metadata.engineVersion, EngineMetadata.currentEngineVersion)
        XCTAssertEqual(state.metadata.stateSchemaVersion, EngineMetadata.currentStateSchemaVersion)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EncounterState.self, from: data)
        XCTAssertEqual(decoded.metadata, state.metadata)
    }

    func testReducerRejectsInvalidTerminalLifecycleJump() {
        let result = LiveStateReducer.reduce(state: .init(lifecycle: .created), event: .encounterCompleted)
        XCTAssertEqual(result.state.lifecycle, .created)
        XCTAssertEqual(result.state.sequence, 1)
    }

    func testReducerAllowsValidTerminalLifecycleProgression() {
        var state = EncounterState(lifecycle: .processing)
        state = LiveStateReducer.reduce(state: state, event: .encounterCompleted).state
        XCTAssertEqual(state.lifecycle, .completed)
        state = LiveStateReducer.reduce(state: state, event: .reviewStarted).state
        XCTAssertEqual(state.lifecycle, .reviewing)
        state = LiveStateReducer.reduce(state: state, event: .retryStarted).state
        XCTAssertEqual(state.lifecycle, .retrying)
    }

    func testValidatedReplayRejectsWrongEncounterAndBrokenSequence() throws {
        let encounterID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let otherID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let branchID = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        let initial = EncounterState(id: encounterID, activeBranchID: branchID)

        let wrongEncounter = EventRecord(
            id: UUID(),
            encounterID: otherID,
            branchID: branchID,
            sequence: 1,
            timestamp: Determinism.timestamp(sequence: 1),
            event: .preparationStarted
        )
        XCTAssertThrowsError(try ReplayEngine.validatedReplay(initial: initial, records: [wrongEncounter])) {
            XCTAssertEqual($0 as? ReplayValidationError, .encounterMismatch(expected: encounterID, found: otherID))
        }

        let gap = EventRecord(
            id: UUID(),
            encounterID: encounterID,
            branchID: branchID,
            sequence: 2,
            timestamp: Determinism.timestamp(sequence: 2),
            event: .preparationStarted
        )
        XCTAssertThrowsError(try ReplayEngine.validatedReplay(initial: initial, records: [gap])) {
            XCTAssertEqual($0 as? ReplayValidationError, .sequenceGap(expected: 1, found: 2))
        }
    }

    func testValidatedReplayRejectsDuplicateAndFutureSchema() {
        let encounterID = UUID(uuidString: "78787878-7878-7878-7878-787878787878")!
        let initial = EncounterState(id: encounterID)
        let first = EventRecord(
            id: UUID(),
            encounterID: encounterID,
            branchID: initial.activeBranchID,
            sequence: 1,
            timestamp: Determinism.timestamp(sequence: 1),
            event: .preparationStarted
        )
        let duplicate = EventRecord(
            id: UUID(),
            encounterID: encounterID,
            branchID: initial.activeBranchID,
            sequence: 1,
            timestamp: Determinism.timestamp(sequence: 1),
            event: .preparationCompleted
        )
        XCTAssertThrowsError(try ReplayEngine.validatedReplay(initial: initial, records: [first, duplicate])) {
            XCTAssertEqual($0 as? ReplayValidationError, .duplicateSequence(1))
        }

        let future = EventRecord(
            id: UUID(),
            schemaVersion: EventRecord.currentSchemaVersion + 1,
            encounterID: encounterID,
            branchID: initial.activeBranchID,
            sequence: 1,
            timestamp: Determinism.timestamp(sequence: 1),
            event: .preparationStarted
        )
        XCTAssertThrowsError(try ReplayEngine.validatedReplay(initial: initial, records: [future])) {
            XCTAssertEqual(
                $0 as? ReplayValidationError,
                .unsupportedSchema(found: EventRecord.currentSchemaVersion + 1, supported: EventRecord.currentSchemaVersion)
            )
        }
    }

    func testRetryDoesNotRewindGlobalEventSequence() {
        let encounterID = UUID(uuidString: "90909090-9090-9090-9090-909090909090")!
        var checkpointState = EncounterState(id: encounterID, lifecycle: .active, sequence: 3)
        checkpointState.conversation.turns.append(.init(speaker: .counterpart, text: "Why Next.js?"))
        let checkpoint = Branching.checkpoint(
            checkpointState,
            id: UUID(uuidString: "91919191-9191-9191-9191-919191919191")!
        )

        var original = checkpointState
        original.sequence = 9

        let session = RetryEngine.begin(from: checkpoint, original: original)
        XCTAssertEqual(session.retry.sequence, 9)
        XCTAssertEqual(
            session.retry.branchLineage.parentCheckpointID(for: session.retry.activeBranchID),
            checkpoint.id
        )

        let next = LiveStateReducer.reduce(
            state: session.retry,
            event: .userSubmitted("A different answer")
        )
        XCTAssertEqual(next.state.sequence, 10)

        let persisted = next.effects.compactMap { effect -> EventRecord? in
            if case let .persistEvent(record) = effect { return record }
            return nil
        }
        XCTAssertEqual(persisted.first?.sequence, 10)
        XCTAssertEqual(persisted.first?.branchID, session.retry.activeBranchID)
    }

    func testTerminalLifecycleStatesCannotBeRevived() {
        for terminal in [EncounterLifecycle.failed, .cancelled] {
            XCTAssertTrue(LifecyclePolicy.isTerminal(terminal))
            XCTAssertFalse(LifecyclePolicy.canTransition(from: terminal, to: .recovering))
            XCTAssertFalse(LifecyclePolicy.canTransition(from: terminal, to: .active))
            XCTAssertFalse(LifecyclePolicy.canTransition(from: terminal, to: .preparing))
        }
    }

    func testRecoveryTransitionsAreExplicitAndNonTerminal() {
        XCTAssertTrue(LifecyclePolicy.canTransition(from: .active, to: .recovering))
        XCTAssertTrue(LifecyclePolicy.canTransition(from: .paused, to: .recovering))
        XCTAssertTrue(LifecyclePolicy.canTransition(from: .recovering, to: .active))
        XCTAssertTrue(LifecyclePolicy.canTransition(from: .recovering, to: .failed))
        XCTAssertFalse(LifecyclePolicy.canTransition(from: .created, to: .recovering))
        XCTAssertFalse(LifecyclePolicy.canTransition(from: .completed, to: .recovering))
    }

    func testGuardrailsOverrideOrdinaryPolicy() {
        let evaluation = AnswerEvaluation(
            answeredQuestion: true,
            relevance: 1,
            specificity: 1
        )

        var redirect = EncounterState(lifecycle: .active)
        redirect.guardrails.action = .redirect
        XCTAssertEqual(PolicyEngine.nextAction(for: redirect, evaluation: evaluation), .closeTopic)

        var stop = EncounterState(lifecycle: .active)
        stop.guardrails.action = .endEncounter
        XCTAssertEqual(PolicyEngine.nextAction(for: stop, evaluation: evaluation), .endEncounter)
    }

    func testGuardrailsPersistThroughStateEncoding() throws {
        var state = EncounterState()
        state.guardrails = .init(allowedDomains: [.interview, .workplace], action: .redirect)
        let decoded = try JSONDecoder().decode(
            EncounterState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded.guardrails, state.guardrails)
    }

    func testGuardrailDecisionIsPersistedAndReplayable() throws {
        let encounterID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let initial = EncounterState(id: encounterID, lifecycle: .active)
        let changed = LiveStateReducer.reduce(
            state: initial,
            event: .guardrailActionChanged(.redirect)
        )
        XCTAssertEqual(changed.state.guardrails.action, .redirect)

        let records = changed.effects.compactMap { effect -> EventRecord? in
            if case let .persistEvent(record) = effect { return record }
            return nil
        }
        XCTAssertEqual(records.first?.kind, "guardrailActionChanged")

        let replayed = try ReplayEngine.validatedReplay(initial: initial, records: records)
        XCTAssertEqual(replayed.guardrails.action, .redirect)
        XCTAssertEqual(replayed, changed.state)
    }

    func testGuardrailDecisionJSONRoundTripPreservesAction() throws {
        let record = EventRecord(
            id: UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!,
            encounterID: UUID(uuidString: "dededede-dede-dede-dede-dededededede")!,
            sequence: 1,
            timestamp: Determinism.timestamp(sequence: 1),
            event: .guardrailActionChanged(.endEncounter)
        )
        let decoded = try JSONDecoder().decode(
            EventRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.kind, "guardrailActionChanged")
    }

}
