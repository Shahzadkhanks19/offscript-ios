import Foundation

/// Adapter-facing speech classification supplied by platform audio analysis.
/// LiveState deliberately does not prescribe RMS, dBFS, ML, or framework-
/// specific VAD thresholds; the platform adapter reports only this measured
/// speech/not-speech classification with a monotonic timestamp.
public struct VoiceActivitySample: Equatable, Sendable {
    public let isSpeech: Bool
    public let elapsedMilliseconds: Int64

    public init(isSpeech: Bool, elapsedMilliseconds: Int64) {
        self.isSpeech = isSpeech
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// Converts timestamped speech classifications into the duration observations
/// consumed by VoiceActivityGate. Timestamps must be monotonic within one
/// capture session; stale/out-of-order samples are ignored.
public struct VoiceActivityNormalizer: Equatable, Sendable {
    private var lastTimestamp: Int64?
    private var speechStartedAt: Int64?
    private var silenceStartedAt: Int64?
    private var speechActive = false

    public init() {}

    public mutating func receive(_ sample: VoiceActivitySample) -> [VoiceActivityObservation] {
        guard sample.elapsedMilliseconds >= 0 else { return [] }
        if let lastTimestamp, sample.elapsedMilliseconds < lastTimestamp {
            return []
        }
        lastTimestamp = sample.elapsedMilliseconds

        if sample.isSpeech {
            if !speechActive {
                speechActive = true
                speechStartedAt = sample.elapsedMilliseconds
                silenceStartedAt = nil
                return [.speechBegan, .speechDuration(milliseconds: 0)]
            }

            // A non-speech interval inside the same physical utterance is only
            // a candidate pause. If speech resumes before the platform closes
            // the utterance, that candidate pause is over and the next silence
            // must start timing from its own first non-speech sample.
            silenceStartedAt = nil

            guard let speechStartedAt else { return [] }
            return [.speechDuration(milliseconds: sample.elapsedMilliseconds - speechStartedAt)]
        }

        guard speechActive else { return [] }
        if silenceStartedAt == nil {
            silenceStartedAt = sample.elapsedMilliseconds
        }
        guard let silenceStartedAt else { return [] }
        return [.silenceDuration(milliseconds: sample.elapsedMilliseconds - silenceStartedAt)]
    }

    /// Closes a speech run when the platform VAD decides speech has ended.
    /// Silence-duration observations alone do not implicitly close it because
    /// VoiceActivityGate owns the semantic meaningful-silence decision.
    public mutating func endSpeech() -> [VoiceActivityObservation] {
        guard speechActive else { return [] }
        speechActive = false
        speechStartedAt = nil
        silenceStartedAt = nil
        return [.speechEnded]
    }

    public mutating func reset() {
        lastTimestamp = nil
        speechStartedAt = nil
        silenceStartedAt = nil
        speechActive = false
    }
}
