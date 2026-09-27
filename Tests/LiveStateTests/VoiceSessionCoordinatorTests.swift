import XCTest
@testable import LiveState

private actor FakeVoiceInput: VoiceInputService {
    private(set) var stops = 0
    func events() async -> AsyncThrowingStream<VoiceInputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func start() async throws {}
    func stop() async { stops += 1 }
}

private actor FakeSpeech: CounterpartSpeechService {
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    func speak(_ text: String) async throws { spoken.append(text) }
    func stop() async { stops += 1 }
}

private actor SuspendedSpeech: CounterpartSpeechService {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var stops = 0

    func speak(_ text: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        stops += 1
        continuation?.resume()
        continuation = nil
    }
}

private actor SequencedSpeech: CounterpartSpeechService {
    private var firstContinuation: CheckedContinuation<Void, Error>?
    private(set) var spoken: [String] = []
    private(set) var stops = 0

    func speak(_ text: String) async throws {
        spoken.append(text)
        if spoken.count == 1 {
            try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
            }
        }
    }

    func stop() async {
        stops += 1
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private enum SpeechTestError: Error { case playbackFailed }

private actor FailingSpeech: CounterpartSpeechService {
    func speak(_ text: String) async throws { throw SpeechTestError.playbackFailed }
    func stop() async {}
}

private actor SupersededFailingSpeech: CounterpartSpeechService {
    private var firstContinuation: CheckedContinuation<Void, Error>?
    private(set) var spoken: [String] = []
    private(set) var stops = 0

    func speak(_ text: String) async throws {
        spoken.append(text)
        if spoken.count == 1 {
            try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
            }
        }
    }

    func stop() async {
        stops += 1
        firstContinuation?.resume(throwing: SpeechTestError.playbackFailed)
        firstContinuation = nil
    }
}

private struct VCEvaluation: EvaluationService {
    func evaluate(turnID: UUID, text: String, context: EvaluationContext, idempotencyKey: UUID) async throws -> AnswerEvaluation {
        .init(answeredQuestion: true, relevance: 1, specificity: 1)
    }
}
private struct VCCounterpart: CounterpartService {
    func respond(to action: PolicyAction, context: CounterpartContext, idempotencyKey: UUID) async throws -> String { "Follow-up" }
}
private struct VCCheckpointStore: CheckpointStore { func save(_ checkpoint: Checkpoint) async throws {} }
private struct VCEventStore: EventStore { func save(_ record: EventRecord) async throws {} }

final class VoiceSessionCoordinatorTests: XCTestCase {
    private func runtime(_ state: EncounterState = .init(lifecycle: .active)) -> EncounterRuntime {
        EncounterRuntime(state: state, runner: EffectRunner(evaluation: VCEvaluation(), counterpart: VCCounterpart(), checkpoints: VCCheckpointStore(), events: VCEventStore()))
    }

    func testFinalTranscriptFlowsThroughRuntime() async throws {
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: FakeVoiceInput(), speech: FakeSpeech(), runtime: runtime)
        try await coordinator.handle(.speechStarted)
        try await coordinator.handle(.transcript(.init(text: "My final answer", isFinal: true)))
        let state = await runtime.state
        XCTAssertEqual(state.user.totalTurns, 1)
        XCTAssertEqual(state.conversation.turns.first?.text, "My final answer")
    }

    func testPartialTranscriptRemainsEphemeral() async throws {
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: FakeVoiceInput(), speech: FakeSpeech(), runtime: runtime)
        try await coordinator.handle(.transcript(.init(text: "partial", isFinal: false)))
        let state = await runtime.state
        let voiceState = await coordinator.voiceState
        XCTAssertTrue(state.conversation.turns.isEmpty)
        XCTAssertEqual(voiceState.partialTranscript, "partial")
    }

    func testBargeInStopsSpeechAndMovesToUserSpeaking() async throws {
        var initial = EncounterState(lifecycle: .active)
        initial.conversation.turnState = .counterpartSpeaking
        let runtime = runtime(initial)
        let speech = FakeSpeech()
        let coordinator = VoiceSessionCoordinator(input: FakeVoiceInput(), speech: speech, runtime: runtime)
        try await coordinator.handle(.interruptedCounterpart)
        let speechStops = await speech.stops
        XCTAssertEqual(speechStops, 1)
        let state = await runtime.state
        XCTAssertEqual(state.user.interruptions, 1)
        XCTAssertEqual(state.conversation.turnState, .userSpeaking)
    }

    func testCounterpartSpeechLifecycleReturnsToIdle() async throws {
        let runtime = runtime()
        let speech = FakeSpeech()
        let coordinator = VoiceSessionCoordinator(input: FakeVoiceInput(), speech: speech, runtime: runtime)

        try await coordinator.speakCounterpart("Opening question")

        let spoken = await speech.spoken
        let state = await runtime.state
        XCTAssertEqual(spoken, ["Opening question"])
        XCTAssertEqual(state.conversation.turnState, .idle)
    }

    func testRawActivityUsesAuthoritativeStateForBargeIn() async throws {
        var initial = EncounterState(lifecycle: .active)
        initial.conversation.turnState = .counterpartSpeaking
        let runtime = runtime(initial)
        let speech = FakeSpeech()
        let coordinator = VoiceSessionCoordinator(
            input: FakeVoiceInput(),
            speech: speech,
            runtime: runtime,
            activityGate: .init(policy: .init(bargeInMilliseconds: 180))
        )

        try await coordinator.handleActivity(.speechBegan)
        try await coordinator.handleActivity(.speechDuration(milliseconds: 179))
        let beforeThresholdStops = await speech.stops
        XCTAssertEqual(beforeThresholdStops, 0)

        try await coordinator.handleActivity(.speechDuration(milliseconds: 180))
        let stops = await speech.stops
        let state = await runtime.state
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(state.user.interruptions, 1)
        XCTAssertEqual(state.conversation.turnState, .userSpeaking)
    }

    func testRawActivityMeaningfulSilenceFlowsIntoLiveState() async throws {
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(
            input: FakeVoiceInput(),
            speech: FakeSpeech(),
            runtime: runtime,
            activityGate: .init(policy: .init(meaningfulSilenceMilliseconds: 900))
        )

        try await coordinator.handleActivity(.speechBegan)
        try await coordinator.handleActivity(.silenceDuration(milliseconds: 899))
        var state = await runtime.state
        XCTAssertEqual(state.conversation.turnState, .userSpeaking)

        try await coordinator.handleActivity(.silenceDuration(milliseconds: 900))
        state = await runtime.state
        XCTAssertEqual(state.conversation.turnState, .silence)
    }

    func testStaleSpeechCompletionCannotOverwriteBargeInState() async throws {
        let runtime = runtime()
        let speech = SuspendedSpeech()
        let coordinator = VoiceSessionCoordinator(
            input: FakeVoiceInput(),
            speech: speech,
            runtime: runtime
        )

        let playback = Task {
            try await coordinator.speakCounterpart("Long counterpart response")
        }

        while await runtime.state.conversation.turnState != .counterpartSpeaking {
            await Task.yield()
        }

        try await coordinator.handle(.interruptedCounterpart)
        try await playback.value

        let state = await runtime.state
        let stops = await speech.stops
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(state.user.interruptions, 1)
        XCTAssertEqual(state.conversation.turnState, .userSpeaking)
    }

    func testNewCounterpartPlaybackSupersedesOlderGeneration() async throws {
        let runtime = runtime()
        let speech = SequencedSpeech()
        let coordinator = VoiceSessionCoordinator(
            input: FakeVoiceInput(),
            speech: speech,
            runtime: runtime
        )

        let first = Task {
            try await coordinator.speakCounterpart("First response")
        }

        while await runtime.state.conversation.turnState != .counterpartSpeaking {
            await Task.yield()
        }

        try await coordinator.speakCounterpart("Replacement response")
        try await first.value

        let spoken = await speech.spoken
        let stops = await speech.stops
        let state = await runtime.state
        XCTAssertEqual(spoken, ["First response", "Replacement response"])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(state.conversation.turnState, .idle)
    }

    func testCurrentSpeechFailureCancelsAuthoritativeSpeechState() async {
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(
            input: FakeVoiceInput(),
            speech: FailingSpeech(),
            runtime: runtime
        )

        do {
            try await coordinator.speakCounterpart("This fails")
            XCTFail("Expected playback failure")
        } catch {}

        let state = await runtime.state
        XCTAssertEqual(state.conversation.turnState, .idle)
    }

    func testSupersededGenerationFailureCannotCancelReplacement() async throws {
        let runtime = runtime()
        let speech = SupersededFailingSpeech()
        let coordinator = VoiceSessionCoordinator(
            input: FakeVoiceInput(),
            speech: speech,
            runtime: runtime
        )

        let first = Task {
            try await coordinator.speakCounterpart("Old response")
        }

        while await runtime.state.conversation.turnState != .counterpartSpeaking {
            await Task.yield()
        }

        try await coordinator.speakCounterpart("Replacement response")

        do {
            try await first.value
            XCTFail("Expected superseded playback to report its transport failure")
        } catch {}

        let spoken = await speech.spoken
        let state = await runtime.state
        XCTAssertEqual(spoken, ["Old response", "Replacement response"])
        XCTAssertEqual(state.conversation.turnState, .idle)
    }

    func testStopStopsBothVoiceDirections() async {
        let input = FakeVoiceInput()
        let speech = FakeSpeech()
        let coordinator = VoiceSessionCoordinator(input: input, speech: speech, runtime: runtime())
        await coordinator.stop()
        let inputStops = await input.stops
        let speechStops = await speech.stops
        XCTAssertEqual(inputStops, 1)
        XCTAssertEqual(speechStops, 1)
    }
}
