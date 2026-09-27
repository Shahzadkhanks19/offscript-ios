import Foundation

public actor VoiceSessionCoordinator {
    private let input: any VoiceInputService
    private let speech: any CounterpartSpeechService
    private let runtime: EncounterRuntime
    private var bridge: VoiceTurnBridge
    private var isRunning = false

    public init(input: any VoiceInputService, speech: any CounterpartSpeechService, runtime: EncounterRuntime, bridge: VoiceTurnBridge = .init()) {
        self.input = input
        self.speech = speech
        self.runtime = runtime
        self.bridge = bridge
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
        if inputEvent == .interruptedCounterpart, before.conversation.turnState == .counterpartSpeaking {
            await speech.stop()
        }
        let events = bridge.receive(inputEvent, encounter: before)
        for event in events {
            _ = try await runtime.send(event)
        }
    }

    public func speakCounterpart(_ text: String) async throws {
        let current = await runtime.state
        guard current.lifecycle == .active else { return }
        try await speech.speak(text)
    }

    public var voiceState: VoiceInputState { bridge.input }
}
