import Foundation

public actor VoiceSessionCoordinator {
    private let input: any VoiceInputService
    private let speech: any CounterpartSpeechService
    private let runtime: EncounterRuntime
    private var bridge: VoiceTurnBridge
    private var activityGate: VoiceActivityGate
    private var isRunning = false

    public init(
        input: any VoiceInputService,
        speech: any CounterpartSpeechService,
        runtime: EncounterRuntime,
        bridge: VoiceTurnBridge = .init(),
        activityGate: VoiceActivityGate = .init()
    ) {
        self.input = input
        self.speech = speech
        self.runtime = runtime
        self.bridge = bridge
        self.activityGate = activityGate
    }

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        do {
            try await input.start()
            for try await event in input.events() {
                guard isRunning else { break }
                try await handle(event)
            }
        } catch {
            isRunning = false
            await input.stop()
            throw error
        }
        isRunning = false
        await input.stop()
    }

    public func stop() async {
        isRunning = false
        await input.stop()
        await speech.stop()
    }

    public func handle(_ inputEvent: VoiceInputEvent) async throws {
        let before = await runtime.state
        let events = bridge.receive(inputEvent, encounter: before)
        if inputEvent == .interruptedCounterpart, before.conversation.turnState == .counterpartSpeaking {
            await speech.stop()
        }
        for event in events {
            _ = try await runtime.send(event)
        }
    }

    /// Accepts raw VAD observations and derives semantic voice events using
    /// authoritative encounter state rather than platform-owned assumptions.
    public func handleActivity(_ observation: VoiceActivityObservation) async throws {
        let state = await runtime.state
        let events = activityGate.receive(
            observation,
            counterpartIsSpeaking: state.conversation.turnState == .counterpartSpeaking
        )
        for event in events {
            try await handle(event)
        }
    }

    public func speakCounterpart(_ text: String) async throws {
        let current = await runtime.state
        guard current.lifecycle == .active else { return }

        _ = try await runtime.send(.counterpartSpeechStarted)
        do {
            try await speech.speak(text)
            _ = try await runtime.send(.counterpartSpeechFinished)
        } catch {
            _ = try? await runtime.send(.counterpartSpeechCancelled)
            throw error
        }
    }

    public var voiceState: VoiceInputState { bridge.input }
}
