import Foundation

/// Converts ephemeral audio/transcription callbacks into authoritative,
/// persistable LiveState events. Partial transcripts remain presentation state;
/// only a non-empty final transcript can become a user turn.
public struct VoiceTurnBridge: Equatable, Sendable {
    public private(set) var input: VoiceInputState
    private var activeUtteranceFinal: String?

    public init(input: VoiceInputState = .init()) {
        self.input = input
        self.activeUtteranceFinal = nil
    }

    public mutating func receive(
        _ event: VoiceInputEvent,
        encounter: EncounterState
    ) -> [SimulationEvent] {
        input = VoiceInputReducer.reduce(state: input, event: event)

        guard encounter.lifecycle == .active else { return [] }

        switch event {
        case .speechStarted:
            activeUtteranceFinal = nil
            return [.userSpeechStarted]

        case let .transcript(transcript):
            guard transcript.isFinal else { return [] }
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            guard activeUtteranceFinal != text else { return [] }
            activeUtteranceFinal = text
            return [.userSubmitted(text)]

        case .speechEnded:
            return [.userSpeechEnded]

        case .silenceStarted:
            return [.userSilenceStarted]

        case .interruptedCounterpart:
            activeUtteranceFinal = nil
            guard encounter.conversation.turnState == .counterpartSpeaking else {
                return [.userSpeechStarted]
            }
            return [.counterpartInterrupted, .userSpeechStarted]
        }
    }
}
