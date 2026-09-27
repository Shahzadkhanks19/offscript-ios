import Foundation

/// Raw, monotonic observations emitted by a platform VAD/audio adapter.
public enum VoiceActivityObservation: Equatable, Sendable {
    case speechBegan
    case speechDuration(milliseconds: Int64)
    case silenceDuration(milliseconds: Int64)
    case speechEnded
}

/// Stateful gate between noisy VAD callbacks and semantic voice input events.
/// Threshold events are emitted at most once per continuous speech/silence run.
public struct VoiceActivityGate: Equatable, Sendable {
    public let policy: VoiceActivityPolicy
    private var speechActive = false
    private var silenceEmitted = false
    private var bargeInEmitted = false

    public init(policy: VoiceActivityPolicy = .init()) {
        self.policy = policy
    }

    public mutating func receive(
        _ observation: VoiceActivityObservation,
        counterpartIsSpeaking: Bool
    ) -> [VoiceInputEvent] {
        switch observation {
        case .speechBegan:
            let shouldEmitStart = !speechActive
            speechActive = true
            silenceEmitted = false
            bargeInEmitted = false
            return shouldEmitStart ? [.speechStarted] : []

        case let .speechDuration(milliseconds):
            guard speechActive, !bargeInEmitted else { return [] }
            guard VoiceActivityEngine.speechDecision(
                durationMilliseconds: milliseconds,
                counterpartIsSpeaking: counterpartIsSpeaking,
                policy: policy
            ) == .bargeIn else { return [] }
            bargeInEmitted = true
            return [.interruptedCounterpart]

        case let .silenceDuration(milliseconds):
            guard !silenceEmitted else { return [] }
            guard VoiceActivityEngine.silenceDecision(
                durationMilliseconds: milliseconds,
                policy: policy
            ) == .meaningfulSilence else { return [] }
            silenceEmitted = true
            return [.silenceStarted]

        case .speechEnded:
            guard speechActive else { return [] }
            speechActive = false
            bargeInEmitted = false
            return [.speechEnded]
        }
    }
}
