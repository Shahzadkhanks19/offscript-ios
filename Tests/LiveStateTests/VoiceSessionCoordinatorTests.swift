import XCTest
@testable import LiveState

private actor FakeVoiceInput: VoiceInputService {
    private(set) var stops = 0
    func events() async -> AsyncThrowingStream<VoiceCaptureEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func start() async throws {}
    func stop() async { stops += 1 }
}

private actor StreamingVoiceInput: VoiceInputService {
    private var continuation: AsyncThrowingStream<VoiceCaptureEvent, Error>.Continuation?
    private(set) var starts = 0
    private(set) var stops = 0

    func events() async -> AsyncThrowingStream<VoiceCaptureEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    var streamReady: Bool { continuation != nil }

    func start() async throws { starts += 1 }

    func stop() async {
        stops += 1
        continuation?.finish()
        continuation = nil
    }

    func yield(_ event: VoiceCaptureEvent) { continuation?.yield(event) }
    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

private actor ScriptedVoiceInput: VoiceInputService {
    private let script: [VoiceCaptureEvent]
    private(set) var stops = 0

    init(_ script: [VoiceCaptureEvent]) {
        self.script = script
    }

    func events() async -> AsyncThrowingStream<VoiceCaptureEvent, Error> {
        let script = self.script
        return AsyncThrowingStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func start() async throws {}
    func stop() async { stops += 1 }
}

private enum VoiceStreamTestError: Error { case failed }

private actor RestartableVoiceInput: VoiceInputService {
    private var continuations: [Int: AsyncThrowingStream<VoiceCaptureEvent, Error>.Continuation] = [:]
    private var nextStreamID = 0
    private(set) var starts = 0
    private(set) var stops = 0

    func events() async -> AsyncThrowingStream<VoiceCaptureEvent, Error> {
        let id = nextStreamID
        nextStreamID += 1
        return AsyncThrowingStream { continuation in
            continuations[id] = continuation
        }
    }

    func start() async throws { starts += 1 }

    func stop() async {
        stops += 1
        // Deliberately do not finish streams: this fake proves the coordinator's
        // generation check rejects callbacks from an obsolete adapter stream.
    }

    func yield(_ event: VoiceCaptureEvent, streamID: Int) {
        continuations[streamID]?.yield(event)
    }

    func finish(streamID: Int) {
        continuations[streamID]?.finish()
        continuations[streamID] = nil
    }

    var streamCount: Int { nextStreamID }
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
        var state = await runtime.state
        XCTAssertEqual(state.user.totalTurns, 0)

        try await coordinator.handle(.speechEnded)
        state = await runtime.state
        XCTAssertEqual(state.user.totalTurns, 1)
        XCTAssertEqual(state.conversation.turns.first?.text, "My final answer")
    }

    func testPartialTranscriptRemainsEphemeral() async throws {
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: FakeVoiceInput(), speech: FakeSpeech(), runtime: runtime)
        try await coordinator.handle(.speechStarted)
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

    func testStopTerminatesLongLivedInputStream() async throws {
        let input = StreamingVoiceInput()
        let coordinator = VoiceSessionCoordinator(input: input, speech: FakeSpeech(), runtime: runtime())

        let session = Task { try await coordinator.start() }
        while !(await input.streamReady) { await Task.yield() }

        await coordinator.stop()
        try await session.value

        let stops = await input.stops
        XCTAssertEqual(stops, 1)
    }

    func testUnexpectedInputStreamFailureStopsOwnedRun() async {
        let input = StreamingVoiceInput()
        let coordinator = VoiceSessionCoordinator(input: input, speech: FakeSpeech(), runtime: runtime())

        let session = Task { try await coordinator.start() }
        while !(await input.streamReady) { await Task.yield() }
        await input.fail(VoiceStreamTestError.failed)

        do {
            try await session.value
            XCTFail("Expected stream failure")
        } catch {}

        let stops = await input.stops
        XCTAssertEqual(stops, 1)
    }

    func testRestartCreatesNewInputSessionAndRejectsObsoleteStreamCallbacks() async throws {
        let input = RestartableVoiceInput()
        let encounterRuntime = runtime()
        let coordinator = VoiceSessionCoordinator(
            input: input,
            speech: FakeSpeech(),
            runtime: encounterRuntime
        )

        let first = Task { try await coordinator.start() }
        while await input.streamCount < 1 { await Task.yield() }

        await coordinator.stop()

        let second = Task { try await coordinator.start() }
        while await input.streamCount < 2 { await Task.yield() }

        await input.yield(.transcript(.init(text: "obsolete", isFinal: true)), streamID: 0)
        await Task.yield()

        var state = await encounterRuntime.state
        XCTAssertTrue(state.conversation.turns.isEmpty)

        await input.yield(.activity(.speechBegan), streamID: 1)
        await input.yield(.transcript(.init(text: "current", isFinal: true)), streamID: 1)
        await input.yield(.activity(.speechEnded), streamID: 1)

        while await encounterRuntime.state.user.totalTurns < 1 { await Task.yield() }
        state = await encounterRuntime.state
        XCTAssertEqual(state.user.totalTurns, 1)
        XCTAssertEqual(state.conversation.turns.last?.text, "current")

        await input.finish(streamID: 0)
        try await first.value
        await coordinator.stop()
        await input.finish(streamID: 1)
        try await second.value

        let starts = await input.starts
        XCTAssertEqual(starts, 2)
    }

    func testCaptureStreamCannotInventSemanticBargeIn() async throws {
        var initial = EncounterState(lifecycle: .active)
        initial.conversation.turnState = .counterpartSpeaking
        let runtime = runtime(initial)
        let input = ScriptedVoiceInput([
            .activity(.speechBegan),
            .activity(.speechDuration(milliseconds: 179)),
            .activity(.speechDuration(milliseconds: 180))
        ])
        let speech = FakeSpeech()
        let coordinator = VoiceSessionCoordinator(
            input: input,
            speech: speech,
            runtime: runtime,
            activityGate: .init(policy: .init(bargeInMilliseconds: 180))
        )

        // This integration test deliberately uses a finite capture stream.
        // Threshold semantics below 180 ms are already proven by
        // VoiceActivityGateTests; here we prove that raw capture observations
        // crossing the coordinator boundary produce exactly one semantic
        // interruption without relying on scheduler timing or polling.
        try await coordinator.start()

        let state = await runtime.state
        let speechStops = await speech.stops
        let inputStops = await input.stops
        XCTAssertEqual(state.user.interruptions, 1)
        XCTAssertEqual(state.conversation.turnState, .userSpeaking)
        XCTAssertEqual(speechStops, 1)
        XCTAssertEqual(inputStops, 1)
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
    func testCommittedCounterpartResponseAutomaticallyFlowsToSpeech() async throws {
        let input = StreamingVoiceInput()
        let speech = FakeSpeech()
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: input, speech: speech, runtime: runtime)

        let session = Task { try await coordinator.start() }
        while !(await input.streamReady) { await Task.yield() }

        try await coordinator.handle(.speechStarted)
        try await coordinator.handle(
            .transcript(.init(text: "My answer", isFinal: true, utteranceID: 1))
        )
        try await coordinator.handle(.speechEnded)

        while await speech.spoken.isEmpty { await Task.yield() }

        // The committed-response observer intentionally dispatches TTS across
        // an asynchronous boundary. Playback becoming visible in the transport
        // does not mean its authoritative completion event has committed yet.
        while await runtime.state.conversation.turnState != .idle {
            await Task.yield()
        }

        let spoken = await speech.spoken
        let state = await runtime.state
        XCTAssertEqual(spoken, ["Follow-up"])
        XCTAssertEqual(state.conversation.turns.map(\.text), ["My answer", "Follow-up"])
        XCTAssertEqual(state.conversation.turnState, .idle)

        await coordinator.stop()
        try await session.value
    }

    func testStoppedCoordinatorDoesNotSpeakLaterRuntimeResponses() async throws {
        let input = StreamingVoiceInput()
        let speech = FakeSpeech()
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: input, speech: speech, runtime: runtime)

        let session = Task { try await coordinator.start() }
        while !(await input.streamReady) { await Task.yield() }
        await coordinator.stop()
        try await session.value

        _ = try await runtime.send(.counterpartResponded("Should remain silent"))
        let spoken = await speech.spoken
        XCTAssertTrue(spoken.isEmpty)
    }

    func testNaturallyFinishedCaptureDetachesRuntimeSpeechObserver() async throws {
        let input = FakeVoiceInput()
        let speech = FakeSpeech()
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: input, speech: speech, runtime: runtime)

        try await coordinator.start()
        _ = try await runtime.send(.counterpartResponded("After capture ended"))

        let spoken = await speech.spoken
        XCTAssertTrue(spoken.isEmpty)
    }

    func testFailedCaptureDetachesRuntimeSpeechObserver() async {
        let input = StreamingVoiceInput()
        let speech = FakeSpeech()
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: input, speech: speech, runtime: runtime)

        let session = Task { try await coordinator.start() }
        while !(await input.streamReady) { await Task.yield() }
        await input.fail(VoiceStreamTestError.failed)

        do {
            try await session.value
            XCTFail("Expected stream failure")
        } catch {}

        do {
            _ = try await runtime.send(.counterpartResponded("After capture failed"))
        } catch {
            XCTFail("Runtime send unexpectedly failed: \(error)")
        }

        let spoken = await speech.spoken
        XCTAssertTrue(spoken.isEmpty)
    }

    func testConcurrentCommittedResponsesSupersedeOlderAutomaticPlayback() async throws {
        let input = StreamingVoiceInput()
        let speech = SequencedSpeech()
        let runtime = runtime()
        let coordinator = VoiceSessionCoordinator(input: input, speech: speech, runtime: runtime)

        let session = Task { try await coordinator.start() }
        while !(await input.streamReady) { await Task.yield() }

        _ = try await runtime.send(.counterpartResponded("First committed response"))
        while await speech.spoken.isEmpty { await Task.yield() }

        _ = try await runtime.send(.counterpartResponded("Newer committed response"))

        // Ordered committed-response delivery means the runtime send itself no
        // longer needs to be held open in a sibling task. The first playback
        // remains suspended in the transport until the second committed record
        // supersedes it, which deterministically exercises replacement.
        while await speech.spoken.count < 2 { await Task.yield() }

        // Seeing the replacement text only proves that transport playback
        // started. Its completion still has to flow through the coordinator
        // and commit counterpartSpeechFinished before LiveState becomes idle.
        while await runtime.state.conversation.turnState != .idle {
            await Task.yield()
        }

        let spoken = await speech.spoken
        let stops = await speech.stops
        let state = await runtime.state
        XCTAssertEqual(spoken, ["First committed response", "Newer committed response"])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(state.conversation.turnState, .idle)

        await coordinator.stop()
        try await session.value
    }

}
