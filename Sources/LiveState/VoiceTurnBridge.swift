import Foundation

/// Converts ephemeral audio/transcription callbacks into authoritative,
/// persistable LiveState events. Partial transcripts remain presentation state;
/// only a non-empty final transcript can become a user turn.
public struct VoiceTurnBridge: Equatable, Sendable {
    public private(set) var input: VoiceInputState
    private var pendingUtteranceFinal: String?
    private var latestTranscriptRevision: UInt64?

    public init(input: VoiceInputState = .init()) {
        self.input = input
        self.pendingUtteranceFinal = nil
        self.latestTranscriptRevision = nil
    }

    /// Clears all ephemeral capture/transcription state between physical
    /// capture sessions. No pending transcript may cross a stop/restart boundary.
    public mutating func reset() {
        input = .init()
        pendingUtteranceFinal = nil
        latestTranscriptRevision = nil
    }

    public mutating func receive(
        _ event: VoiceInputEvent,
        encounter: EncounterState
    ) -> [SimulationEvent] {
        input = VoiceInputReducer.reduce(state: input, event: event)

        guard encounter.lifecycle == .active else { return [] }

        switch event {
        case .speechStarted:
            pendingUtteranceFinal = nil
            latestTranscriptRevision = nil
            return [.userSpeechStarted]

        case let .transcript(transcript):
            if let latestTranscriptRevision, transcript.revision < latestTranscriptRevision {
                return []
            }
            latestTranscriptRevision = transcript.revision
            guard transcript.isFinal else { return [] }
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            pendingUtteranceFinal = text
            return []

        case .speechEnded:
            guard let text = pendingUtteranceFinal else {
                return [.userSpeechEnded]
            }
            pendingUtteranceFinal = nil
            return [.userSubmitted(text), .userSpeechEnded]

        case .silenceStarted:
            guard let text = pendingUtteranceFinal else {
                return [.userSilenceStarted]
            }
            pendingUtteranceFinal = nil
            return [.userSubmitted(text), .userSilenceStarted]

        case .interruptedCounterpart:
            pendingUtteranceFinal = nil
            guard encounter.conversation.turnState == .counterpartSpeaking else {
                return [.userSpeechStarted]
            }
            return [.counterpartInterrupted, .userSpeechStarted]
        }
    }
}
