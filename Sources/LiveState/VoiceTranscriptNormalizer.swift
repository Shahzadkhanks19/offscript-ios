import Foundation

/// Adapter-side normalizer that converts framework transcription callbacks into
/// LiveState's complete-snapshot contract. It owns no encounter truth.
public struct VoiceTranscriptNormalizer: Equatable, Sendable {
    public private(set) var activeUtteranceID: UInt64?
    public private(set) var revision: UInt64 = 0
    private var nextUtteranceID: UInt64 = 0

    public init() {}

    /// Starts a new physical utterance and returns its stable adapter identity.
    /// IDs are monotonic within one capture-session lifetime.
    @discardableResult
    public mutating func beginUtterance() -> UInt64 {
        nextUtteranceID &+= 1
        activeUtteranceID = nextUtteranceID
        revision = 0
        return nextUtteranceID
    }

    /// Produces a complete best-known transcript snapshot for the active
    /// utterance. Callbacks without a speech boundary are rejected.
    public mutating func snapshot(
        text: String,
        isFinal: Bool,
        confidence: Double? = nil
    ) -> VoiceTranscript? {
        guard let activeUtteranceID else { return nil }
        revision &+= 1
        return VoiceTranscript(
            text: text,
            isFinal: isFinal,
            confidence: confidence,
            revision: revision,
            utteranceID: activeUtteranceID
        )
    }

    /// Closes the current utterance. Late framework callbacks can no longer be
    /// normalized until the adapter reports a new physical speech boundary.
    public mutating func endUtterance() {
        activeUtteranceID = nil
        revision = 0
    }

    /// Clears capture-session identity so no adapter callback can cross a
    /// stop/restart boundary.
    public mutating func reset() {
        activeUtteranceID = nil
        revision = 0
        nextUtteranceID = 0
    }
}
