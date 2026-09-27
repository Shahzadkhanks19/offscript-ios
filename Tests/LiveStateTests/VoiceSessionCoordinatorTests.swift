import XCTest
@testable import LiveState

private actor FakeVoiceInput: VoiceInputService {
    private(set) var stops = 0
    func events() -> AsyncThrowingStream<VoiceInputEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func start() async throws {}
    func stop() async { stops += 1 }
}

private actor FakeSpeech: CounterpartSpeechService {
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    func speak(_ text: String) async throws { spoken.append(text) }
    func stop() async { stops += 1 }
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
        XCTAssertTrue(await runtime.state.conversation.turns.isEmpty)
        XCTAssertEqual(await coordinator.voiceState.partialTranscript, "partial")
    }

    func testBargeInStopsSpeechAndMovesToUserSpeaking() async throws {
        var initial = EncounterState(lifecycle: .active)
        initial.conversation.turnState = .counterpartSpeaking
        let runtime = runtime(initial)
        let speech = FakeSpeech()
        let coordinator = VoiceSessionCoordinator(input: FakeVoiceInput(), speech: speech, runtime: runtime)
        try await coordinator.handle(.interruptedCounterpart)
        XCTAssertEqual(await speech.stops, 1)
        let state = await runtime.state
        XCTAssertEqual(state.user.interruptions, 1)
        XCTAssertEqual(state.conversation.turnState, .userSpeaking)
    }

    func testStopStopsBothVoiceDirections() async {
        let input = FakeVoiceInput()
        let speech = FakeSpeech()
        let coordinator = VoiceSessionCoordinator(input: input, speech: speech, runtime: runtime())
        await coordinator.stop()
        XCTAssertEqual(await input.stops, 1)
        XCTAssertEqual(await speech.stops, 1)
    }
}
