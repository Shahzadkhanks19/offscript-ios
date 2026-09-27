import Foundation

/// Framework-independent realtime voice boundary.
///
/// Apple Speech/AVFoundation adapters will translate platform callbacks into
/// these values. LiveState itself never imports those frameworks.
public struct VoiceTranscript: Equatable, Sendable, Codable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Double?

    public init(text: String, isFinal: Bool, confidence: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence.map { min(max($0, 0), 1) }
    }
}

public enum VoiceInputEvent: Equatable, Sendable, Codable {
    case speechStarted
    case transcript(VoiceTranscript)
    case speechEnded
    case silenceStarted
    case interruptedCounterpart
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
    func events() -> AsyncThrowingStream<VoiceInputEvent, Error>
    func start() async throws
    func stop() async
}

public protocol CounterpartSpeechService: Sendable {
    func speak(_ text: String) async throws
    func stop() async
}
