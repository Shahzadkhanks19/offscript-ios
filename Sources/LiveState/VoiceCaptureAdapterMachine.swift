import Foundation

/// Ownership token for one physical capture run. Platform callbacks must carry
/// the token they were created under so callbacks from an obsolete audio/
/// transcription task cannot enter a newer run.
public struct VoiceCaptureGeneration: Hashable, Equatable, Sendable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Framework-neutral callbacks produced by an Apple/platform capture layer.
/// They contain transport facts and measured observations only; semantic turn
/// policy remains downstream in VoiceSessionCoordinator.
public enum VoiceCaptureAdapterInput: Equatable, Sendable {
    case session(VoiceCaptureSessionEvent)
    case activity(VoiceActivitySample)
    case transcript(text: String, isFinal: Bool, confidence: Double?)
    case speechEnded
}

public struct VoiceCaptureAdapterOutput: Equatable, Sendable {
    public let recoveryAction: VoiceCaptureRecoveryAction
    public let events: [VoiceCaptureEvent]

    public init(
        recoveryAction: VoiceCaptureRecoveryAction = .none,
        events: [VoiceCaptureEvent] = []
    ) {
        self.recoveryAction = recoveryAction
        self.events = events
    }
}

/// Single deterministic entry point for future AVFoundation/Speech callbacks.
/// The platform adapter feeds facts in and performs only the returned recovery
/// action plus event delivery; it does not reproduce LiveState policy.
public struct VoiceCaptureAdapterMachine: Equatable, Sendable {
    public private(set) var state: VoiceCaptureAdapterState
    public private(set) var generation: VoiceCaptureGeneration

    public init(state: VoiceCaptureAdapterState = .init()) {
        self.state = state
        self.generation = .init(rawValue: 0)
    }

    /// Starts a new callback ownership generation. The returned token must be
    /// captured by framework tasks/closures and supplied back with callbacks.
    /// Starting a generation also clears transient run state.
    @discardableResult
    public mutating func beginGeneration() -> VoiceCaptureGeneration {
        generation = .init(rawValue: generation.rawValue &+ 1)
        state.reset()
        return generation
    }

    /// Receives a callback owned by a specific physical capture generation.
    /// Obsolete callbacks are rejected before they can mutate adapter state.
    public mutating func receive(
        _ input: VoiceCaptureAdapterInput,
        generation callbackGeneration: VoiceCaptureGeneration
    ) -> VoiceCaptureAdapterOutput {
        guard callbackGeneration == generation else { return .init() }
        return receiveCurrent(input)
    }

    /// Convenience entry point for deterministic playgrounds/tests that do not
    /// model asynchronous framework callback ownership explicitly.
    public mutating func receive(_ input: VoiceCaptureAdapterInput) -> VoiceCaptureAdapterOutput {
        receiveCurrent(input)
    }

    public mutating func reset() {
        generation = .init(rawValue: generation.rawValue &+ 1)
        state.reset()
    }

    private mutating func receiveCurrent(
        _ input: VoiceCaptureAdapterInput
    ) -> VoiceCaptureAdapterOutput {
        switch input {
        case let .session(event):
            return .init(recoveryAction: state.receive(event))

        case let .activity(sample):
            let events = state.activitySample(
                isSpeech: sample.isSpeech,
                elapsedMilliseconds: sample.elapsedMilliseconds
            )

            if events.contains(.activity(.speechBegan)) {
                _ = state.speechBegan()
            }
            return .init(events: events)

        case let .transcript(text, isFinal, confidence):
            guard let event = state.transcript(
                text: text,
                isFinal: isFinal,
                confidence: confidence
            ) else { return .init() }
            return .init(events: [event])

        case .speechEnded:
            return .init(events: state.speechEnded())
        }
    }
}
