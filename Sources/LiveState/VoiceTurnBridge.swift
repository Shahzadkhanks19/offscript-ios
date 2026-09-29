import Foundation

/// Converts ephemeral audio/transcription callbacks into authoritative,
/// persistable LiveState events. Partial transcripts remain presentation state;
/// only a non-empty final transcript can become a user turn.
public struct VoiceTurnBridge: Equatable, Sendable {
    public private(set) var input: VoiceInputState
    private var pendingUtteranceFinal: String?
    private var latestTranscriptRevision: UInt64?
    private var activeUtteranceID: UInt64?
    private var utteranceActive: Bool
    private var closedUtteranceIDs: Set<UInt64>

    public init(input: VoiceInputState = .init()) {
        self.input = input
        self.pendingUtteranceFinal = nil
        self.latestTranscriptRevision = nil
        self.activeUtteranceID = nil
        self.utteranceActive = false
        self.closedUtteranceIDs = []
    }

    /// Clears all ephemeral capture/transcription state between physical
    /// capture sessions. No pending transcript may cross a stop/restart boundary.
    public mutating func reset() {
        input = .init()
        pendingUtteranceFinal = nil
        latestTranscriptRevision = nil
        activeUtteranceID = nil
        utteranceActive = false
        closedUtteranceIDs.removeAll(keepingCapacity: true)
    }

    public mutating func receive(
        _ event: VoiceInputEvent,
        encounter: EncounterState
    ) -> [SimulationEvent] {
        // Reject callbacks that cannot belong to the current semantic utterance
        // before they are allowed to mutate ephemeral presentation state.
        guard encounter.lifecycle == .active else { return [] }
        if case let .transcript(transcript) = event {
            guard utteranceActive else { return [] }
            if let utteranceID = transcript.utteranceID {
                guard !closedUtteranceIDs.contains(utteranceID) else { return [] }
                if let activeUtteranceID {
                    guard activeUtteranceID == utteranceID else { return [] }
                }
            }
            if let latestTranscriptRevision, transcript.revision < latestTranscriptRevision {
                return []
            }
        }

        input = VoiceInputReducer.reduce(state: input, event: event)

        switch event {
        case .speechStarted:
            closeActiveUtterance()
            pendingUtteranceFinal = nil
            latestTranscriptRevision = nil
            activeUtteranceID = nil
            utteranceActive = true
            return [.userSpeechStarted]

        case let .transcript(transcript):
            if let utteranceID = transcript.utteranceID, activeUtteranceID == nil {
                activeUtteranceID = utteranceID
            }
            latestTranscriptRevision = transcript.revision
            guard transcript.isFinal else { return [] }
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            pendingUtteranceFinal = text
            return []

        case .speechEnded:
            closeActiveUtterance()
            utteranceActive = false
            guard let text = pendingUtteranceFinal else {
                return [.userSpeechEnded]
            }
            pendingUtteranceFinal = nil
            return [.userSubmitted(text), .userSpeechEnded]

        case .silenceStarted:
            closeActiveUtterance()
            utteranceActive = false
            guard let text = pendingUtteranceFinal else {
                return [.userSilenceStarted]
            }
            pendingUtteranceFinal = nil
            return [.userSubmitted(text), .userSilenceStarted]

        case .interruptedCounterpart:
            closeActiveUtterance()
            pendingUtteranceFinal = nil
            latestTranscriptRevision = nil
            activeUtteranceID = nil
            utteranceActive = true
            guard encounter.conversation.turnState == .counterpartSpeaking else {
                return [.userSpeechStarted]
            }
            return [.counterpartInterrupted, .userSpeechStarted]
        }
    }

    private mutating func closeActiveUtterance() {
        if let activeUtteranceID {
            closedUtteranceIDs.insert(activeUtteranceID)
        }
        activeUtteranceID = nil
    }
}
