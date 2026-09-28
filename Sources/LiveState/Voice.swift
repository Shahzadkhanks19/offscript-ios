import Foundation

/// Framework-independent realtime voice boundary.
///
/// Apple Speech/AVFoundation adapters will translate platform callbacks into
/// these values. LiveState itself never imports those frameworks.
public struct VoiceTranscript: Equatable, Sendable, Codable {
    /// Complete best-known text for the current utterance. Platform adapters
    /// must normalize incremental ASR segments into this snapshot contract.
    public let text: String
    public let isFinal: Bool
    public let confidence: Double?

    /// Monotonic revision within one utterance. A higher revision supersedes a
    /// lower one; adapters should restart at zero for each new speech boundary.
    public let revision: UInt64

    /// Capture-adapter utterance identity. When supplied, this must remain
    /// stable for every snapshot belonging to the same physical utterance.
    /// The bridge uses it to reject callbacks that arrive after that utterance
    /// has already ended and a new speech boundary has begun.
    public let utteranceID: UInt64?

    public init(
        text: String,
        isFinal: Bool,
        confidence: Double? = nil,
        revision: UInt64 = 0,
        utteranceID: UInt64? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence.map { min(max($0, 0), 1) }
        self.revision = revision
        self.utteranceID = utteranceID
    }
}

public enum VoiceInputEvent: Equatable, Sendable, Codable {
    case speechStarted
    case transcript(VoiceTranscript)
    case speechEnded
    case silenceStarted
    case interruptedCounterpart
}

/// Raw, framework-independent observations emitted by the platform capture
/// adapter. The adapter reports what it measured; the coordinator owns the
/// semantic decisions such as meaningful silence and barge-in.
public enum VoiceCaptureEvent: Equatable, Sendable {
    case activity(VoiceActivityObservation)
    case transcript(VoiceTranscript)
}

public struct VoiceInputState: Equatable, Sendable, Codable {
    public var isCapturing: Bool
    public var partialTranscript: String
    public var lastFinalTranscript: String?
    public var isSilent: Bool

    public init(
        isCapturing: Bool = false,
        partialTranscript: String = "",
        lastFinalTranscript: String? = nil,
        isSilent: Bool = false
    ) {
        self.isCapturing = isCapturing
        self.partialTranscript = partialTranscript
        self.lastFinalTranscript = lastFinalTranscript
        self.isSilent = isSilent
    }
}

public enum VoiceInputReducer {
    public static func reduce(
        state: VoiceInputState,
        event: VoiceInputEvent
    ) -> VoiceInputState {
        var next = state

        switch event {
        case .speechStarted:
            next.isCapturing = true
            next.isSilent = false
            next.partialTranscript = ""

        case let .transcript(transcript):
            next.isCapturing = true
            next.isSilent = false
            if transcript.isFinal {
                next.lastFinalTranscript = transcript.text
                next.partialTranscript = ""
            } else {
                next.partialTranscript = transcript.text
            }

        case .speechEnded:
            next.isCapturing = false
            next.partialTranscript = ""

        case .silenceStarted:
            next.isCapturing = false
            next.isSilent = true

        case .interruptedCounterpart:
            next.isCapturing = true
            next.isSilent = false
        }

        return next
    }
}

public protocol VoiceInputService: Sendable {
    func events() async -> AsyncThrowingStream<VoiceCaptureEvent, Error>
    func start() async throws
    func stop() async
}

public protocol CounterpartSpeechService: Sendable {
    func speak(_ text: String) async throws
    func stop() async
}
