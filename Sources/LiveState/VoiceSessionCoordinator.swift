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
    private var automaticSpeechFailures: [UUID: String] = [:]
    private var automaticSpeechTasks: [UUID: Task<Void, Never>] = [:]
    private var nextAutomaticSpeechAdmission: UInt64 = 0
    private var automaticSpeechAdmissionTurn: UInt64 = 1
    private var voiceSessionGeneration: UInt64 = 0

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
        voiceSessionGeneration &+= 1
        let sessionGeneration = voiceSessionGeneration
        activityGate.reset()
        bridge.reset()
        // Automatic speech bookkeeping belongs to one capture session. Runtime
        // record IDs deduplicate observer delivery only while that session is
        // alive; failures are likewise presentation diagnostics, not durable
        // encounter history.
        handledCounterpartResponseRecords.removeAll(keepingCapacity: true)
        automaticSpeechFailures.removeAll(keepingCapacity: true)
        automaticSpeechTasks.removeAll(keepingCapacity: true)
        nextAutomaticSpeechAdmission = 0
        automaticSpeechAdmissionTurn = 1
        if runtimeObserverID == nil {
            let (stream, continuation) = AsyncStream<(UUID, String)>.makeStream()
            committedResponseContinuation = continuation
            committedResponseConsumer = Task { [weak self] in
                for await (recordID, text) in stream {
                    guard let self else { return }
                    await self.enqueueCommittedCounterpartResponse(text, recordID: recordID, sessionGeneration: sessionGeneration)
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
                await teardownOwnedSession()
            }
            throw error
        }

        guard generation == runGeneration else { return }
        await teardownOwnedSession()
    }

    public func stop() async {
        await teardownOwnedSession()
    }

    private func teardownOwnedSession() async {
        let wasRunning = isRunning
        isRunning = false
        if wasRunning {
            runGeneration &+= 1
        }
        voiceSessionGeneration &+= 1
        speechGeneration &+= 1
        activeSpeechGeneration = nil
        let playbackID = activePlaybackID
        activePlaybackID = nil
        activityGate.reset()
        bridge.reset()
        await detachRuntimeObserver()
        for task in automaticSpeechTasks.values {
            task.cancel()
        }
        automaticSpeechTasks.removeAll(keepingCapacity: true)

        // Teardown is deliberately idempotent at the coordinator boundary:
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

    /// Accepts committed responses in event order without making ingestion
    /// wait for long-lived TTS transport. Playback itself is independently
    /// replaceable: a newer committed response can enter the coordinator and
    /// supersede the currently active playback by SpeechPlaybackID.
    private func enqueueCommittedCounterpartResponse(_ text: String, recordID: UUID, sessionGeneration: UInt64) {
        guard isRunning, sessionGeneration == voiceSessionGeneration else { return }
        guard handledCounterpartResponseRecords.insert(recordID).inserted else { return }

        nextAutomaticSpeechAdmission &+= 1
        let admission = nextAutomaticSpeechAdmission
        let task = Task<Void, Never> { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await self.speakCommittedCounterpartResponse(
                text,
                recordID: recordID,
                admission: admission,
                sessionGeneration: sessionGeneration
            )
        }
        automaticSpeechTasks[recordID] = task
    }

    private func speakCommittedCounterpartResponse(_ text: String, recordID: UUID, admission: UInt64, sessionGeneration: UInt64) async {
        defer { automaticSpeechTasks[recordID] = nil }
        guard !Task.isCancelled, sessionGeneration == voiceSessionGeneration else { return }
        // Tasks may be scheduled in any order even though admissions are
        // allocated by the ordered runtime consumer. Wait only for admission
        // ownership here; never wait for the predecessor's TTS lifetime.
        while admission != automaticSpeechAdmissionTurn {
            guard !Task.isCancelled, sessionGeneration == voiceSessionGeneration else { return }
            await Task.yield()
        }
        automaticSpeechAdmissionTurn &+= 1
        do {
            let generation = try await performCounterpartSpeech(text)
            guard generation == speechGeneration else { return }
            automaticSpeechFailures[recordID] = nil
        } catch let failure as CounterpartSpeechAttemptFailure {
            guard failure.generation == speechGeneration else {
                // A newer playback intentionally superseded this attempt.
                // Its transport may report cancellation as an error, but that
                // is expected control flow rather than a user-visible failure.
                automaticSpeechFailures[recordID] = nil
                return
            }
            automaticSpeechFailures[recordID] = String(describing: failure.underlying)
        } catch {
            automaticSpeechFailures[recordID] = String(describing: error)
        }
    }

    public func automaticSpeechFailure(for recordID: UUID) -> String? {
        automaticSpeechFailures[recordID]
    }

    private struct CounterpartSpeechAttemptFailure: Error {
        let generation: UInt64
        let underlying: any Error
    }

    @discardableResult
    private func performCounterpartSpeech(_ text: String) async throws -> UInt64 {
        let current = await runtime.state
        guard current.lifecycle == .active else { return speechGeneration }

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
            guard generation == speechGeneration else { return generation }
        }

        activeSpeechGeneration = generation
        activePlaybackID = playbackID
        _ = try await runtime.send(.counterpartSpeechStarted)
        do {
            try await speech.speak(text, playbackID: playbackID)
            guard generation == speechGeneration else { return generation }
            activeSpeechGeneration = nil
            activePlaybackID = nil
            _ = try await runtime.send(.counterpartSpeechFinished)
            return generation
        } catch {
            guard generation == speechGeneration else {
                throw CounterpartSpeechAttemptFailure(generation: generation, underlying: error)
            }
            activeSpeechGeneration = nil
            activePlaybackID = nil
            _ = try? await runtime.send(.counterpartSpeechCancelled)
            throw CounterpartSpeechAttemptFailure(generation: generation, underlying: error)
        }
    }

    public func speakCounterpart(_ text: String) async throws {
        do {
            _ = try await performCounterpartSpeech(text)
        } catch let failure as CounterpartSpeechAttemptFailure {
            throw failure.underlying
        }
    }

    public var voiceState: VoiceInputState { bridge.input }
}
