import Foundation

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

    public init(state: VoiceCaptureAdapterState = .init()) {
        self.state = state
    }

    public mutating func receive(_ input: VoiceCaptureAdapterInput) -> VoiceCaptureAdapterOutput {
        switch input {
        case let .session(event):
            return .init(recoveryAction: state.receive(event))

        case let .activity(sample):
            let events = state.activitySample(
                isSpeech: sample.isSpeech,
                elapsedMilliseconds: sample.elapsedMilliseconds
            )

            // Transcript identity follows the physical speech run. Only a
            // newly observed speech boundary opens a new utterance.
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

    public mutating func reset() {
        state.reset()
    }
}
