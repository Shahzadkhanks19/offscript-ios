import Foundation

public actor VoiceSessionCoordinator {
    private let input: any VoiceInputService
    private let speech: any CounterpartSpeechService
    private let runtime: EncounterRuntime
    private var bridge: VoiceTurnBridge
    private var activityGate: VoiceActivityGate
    private var isRunning = false
    private var runGeneration: UInt64 = 0
    private var speechGeneration: UInt64 = 0

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
        runGeneration &+= 1
        let generation = runGeneration

        do {
            try await input.start()
            guard isRunning, generation == runGeneration else {
                await input.stop()
                return
            }

            let stream = await input.events()
            for try await event in stream {
                guard isRunning, generation == runGeneration else { break }
                try await handle(event)
            }
        } catch {
            let ownsRun = generation == runGeneration
            if ownsRun {
                isRunning = false
                runGeneration &+= 1
                await input.stop()
            }
            throw error
        }

        guard generation == runGeneration else { return }
        isRunning = false
        runGeneration &+= 1
        await input.stop()
    }

    public func stop() async {
        guard isRunning else {
            speechGeneration &+= 1
            await speech.stop()
            return
        }

        isRunning = false
        runGeneration &+= 1
        speechGeneration &+= 1
        await input.stop()
        await speech.stop()
    }

    public func handle(_ inputEvent: VoiceInputEvent) async throws {
        let before = await runtime.state
        let events = bridge.receive(inputEvent, encounter: before)
        if inputEvent == .interruptedCounterpart, before.conversation.turnState == .counterpartSpeaking {
            speechGeneration &+= 1
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

        speechGeneration &+= 1
        let generation = speechGeneration

        let beforeStart = await runtime.state
        if beforeStart.conversation.turnState == .counterpartSpeaking {
            await speech.stop()
            guard generation == speechGeneration else { return }
        }

        _ = try await runtime.send(.counterpartSpeechStarted)
        do {
            try await speech.speak(text)
            guard generation == speechGeneration else { return }
            _ = try await runtime.send(.counterpartSpeechFinished)
        } catch {
            guard generation == speechGeneration else { throw error }
            _ = try? await runtime.send(.counterpartSpeechCancelled)
            throw error
        }
    }

    public var voiceState: VoiceInputState { bridge.input }
}
