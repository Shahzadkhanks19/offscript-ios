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
    private var speechStartEmitted = false
    private var beganWhileCounterpartSpeaking = false

    public init(policy: VoiceActivityPolicy = .init()) {
        self.policy = policy
    }

    public mutating func receive(
        _ observation: VoiceActivityObservation,
        counterpartIsSpeaking: Bool
    ) -> [VoiceInputEvent] {
        switch observation {
        case .speechBegan:
            guard !speechActive else { return [] }
            speechActive = true
            silenceEmitted = false
            bargeInEmitted = false
            beganWhileCounterpartSpeaking = counterpartIsSpeaking
            speechStartEmitted = !counterpartIsSpeaking
            return speechStartEmitted ? [.speechStarted] : []

        case let .speechDuration(milliseconds):
            guard speechActive, !bargeInEmitted else { return [] }
            guard VoiceActivityEngine.speechDecision(
                durationMilliseconds: milliseconds,
                counterpartIsSpeaking: beganWhileCounterpartSpeaking || counterpartIsSpeaking,
                policy: policy
            ) == .bargeIn else { return [] }
            bargeInEmitted = true
            speechStartEmitted = true
            return [.interruptedCounterpart]

        case let .silenceDuration(milliseconds):
            guard speechActive, speechStartEmitted, !silenceEmitted else { return [] }
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
            beganWhileCounterpartSpeaking = false
            let shouldEmitEnd = speechStartEmitted
            speechStartEmitted = false
            return shouldEmitEnd ? [.speechEnded] : []
        }
    }
}
