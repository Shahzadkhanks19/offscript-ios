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
    private var activeSpeechGeneration: UInt64?
    private var activePlaybackID: SpeechPlaybackID?
    private var runtimeObserverID: UUID?
    private var committedResponseContinuation: AsyncStream<(UUID, String)>.Continuation?
    private var committedResponseConsumer: Task<Void, Never>?
    private var handledCounterpartResponseRecords: Set<UUID> = []
    private var automaticSpeechFailures: [UUID: String] = []

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
        activityGate.reset()
        bridge.reset()
        if runtimeObserverID == nil {
            let (stream, continuation) = AsyncStream<(UUID, String)>.makeStream()
            committedResponseContinuation = continuation
            committedResponseConsumer = Task { [weak self] in
                for await (recordID, text) in stream {
                    guard let self else { return }
                    await self.speakCommittedCounterpartResponse(text, recordID: recordID)
                }
            }
            runtimeObserverID = await runtime.observe { record, _ in
                guard case let .counterpartResponded(text) = record.event else { return }
                // Runtime observation stays synchronous/non-suspending while a
                // single consumer preserves committed-event delivery order.
                continuation.yield((record.id, text))
            }
        }
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
                switch event {
                case let .activity(observation):
                    try await handleActivity(observation)
                case let .transcript(transcript):
                    try await handle(.transcript(transcript))
                }
            }
        } catch {
            let ownsRun = generation == runGeneration
            if ownsRun {
                isRunning = false
                runGeneration &+= 1
                await detachRuntimeObserver()
                await input.stop()
            }
            throw error
        }

        guard generation == runGeneration else { return }
        isRunning = false
        runGeneration &+= 1
        await detachRuntimeObserver()
        await input.stop()
    }

    public func stop() async {
        let wasRunning = isRunning
        isRunning = false
        if wasRunning {
            runGeneration &+= 1
        }
        speechGeneration &+= 1
        activeSpeechGeneration = nil
        let playbackID = activePlaybackID
        activePlaybackID = nil
        activityGate.reset()
        bridge.reset()
        await detachRuntimeObserver()

        // Stopping is deliberately idempotent at the coordinator boundary:
        // adapters must tolerate stop even when capture has not started.
        await input.stop()
        await speech.stop(playbackID: playbackID)
    }

    public func handle(_ inputEvent: VoiceInputEvent) async throws {
        let before = await runtime.state
        let events = bridge.receive(inputEvent, encounter: before)
        if inputEvent == .interruptedCounterpart, before.conversation.turnState == .counterpartSpeaking {
            speechGeneration &+= 1
            let playbackID = activePlaybackID
            activeSpeechGeneration = nil
            activePlaybackID = nil
            await speech.stop(playbackID: playbackID)
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

    private func detachRuntimeObserver() async {
        if let runtimeObserverID {
            await runtime.removeObserver(runtimeObserverID)
            self.runtimeObserverID = nil
        }
        committedResponseContinuation?.finish()
        committedResponseContinuation = nil
        committedResponseConsumer?.cancel()
        committedResponseConsumer = nil
    }

    private func speakCommittedCounterpartResponse(_ text: String, recordID: UUID) async {
        guard isRunning else { return }
        guard handledCounterpartResponseRecords.insert(recordID).inserted else { return }
        do {
            try await speakCounterpart(text)
            automaticSpeechFailures[recordID] = nil
        } catch {
            // The authoritative speech lifecycle is repaired by
            // speakCounterpart before the transport error reaches this layer.
            // Keep the failure observable instead of silently swallowing it;
            // UI/adapters can decide whether to offer retry or fallback audio.
            automaticSpeechFailures[recordID] = String(describing: error)
        }
    }

    public func automaticSpeechFailure(for recordID: UUID) -> String? {
        automaticSpeechFailures[recordID]
    }

    public func speakCounterpart(_ text: String) async throws {
        let current = await runtime.state
        guard current.lifecycle == .active else { return }

        speechGeneration &+= 1
        let generation = speechGeneration
        let playbackID = SpeechPlaybackID(rawValue: generation)

        // Transport ownership is coordinator state, not encounter turn state.
        // A newly committed counterpart response may legitimately change the
        // authoritative turn state before the older TTS transport has stopped.
        // Therefore supersession must follow the active playback generation.
        if activeSpeechGeneration != nil {
            let supersededPlaybackID = activePlaybackID
            await speech.stop(playbackID: supersededPlaybackID)
            guard generation == speechGeneration else { return }
        }

        activeSpeechGeneration = generation
        activePlaybackID = playbackID
        _ = try await runtime.send(.counterpartSpeechStarted)
        do {
            try await speech.speak(text, playbackID: playbackID)
            guard generation == speechGeneration else { return }
            activeSpeechGeneration = nil
            activePlaybackID = nil
            _ = try await runtime.send(.counterpartSpeechFinished)
        } catch {
            guard generation == speechGeneration else { throw error }
            activeSpeechGeneration = nil
            activePlaybackID = nil
            _ = try? await runtime.send(.counterpartSpeechCancelled)
            throw error
        }
    }

    public var voiceState: VoiceInputState { bridge.input }
}
