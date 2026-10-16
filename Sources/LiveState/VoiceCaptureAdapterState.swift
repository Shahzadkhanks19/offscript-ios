import Foundation

/// Framework-independent state machine owned by a platform voice adapter.
/// It composes transport lifecycle, transcript identity, and raw activity
/// normalization while leaving semantic VAD policy and EncounterState ownership
/// to VoiceSessionCoordinator.
public struct VoiceCaptureAdapterState: Equatable, Sendable {
    public private(set) var session: VoiceCaptureSessionState
    public private(set) var transcripts: VoiceTranscriptNormalizer
    public private(set) var activity: VoiceActivityNormalizer

    public init(
        session: VoiceCaptureSessionState = .idle,
        transcripts: VoiceTranscriptNormalizer = .init(),
        activity: VoiceActivityNormalizer = .init()
    ) {
        self.session = session
        self.transcripts = transcripts
        self.activity = activity
    }

    /// Applies a transport callback and returns the deterministic hardware
    /// action the platform adapter should perform next.
    @discardableResult
    public mutating func receive(
        _ event: VoiceCaptureSessionEvent
    ) -> VoiceCaptureRecoveryAction {
        let previous = session
        let action = VoiceCaptureRecoveryPolicy.action(state: previous, event: event)
        session = VoiceCaptureSessionReducer.reduce(state: previous, event: event)

        switch event {
        case .interruptionBegan, .routeChanged, .stopRequested,
             .permissionDenied, .permissionRestricted, .streamFailed,
             .recoveryFailed:
            resetCaptureRun()
        default:
            break
        }

        return action
    }

    /// Opens transcript identity only while physical capture is running.
    @discardableResult
    public mutating func speechBegan() -> UInt64? {
        guard session == .running, transcripts.activeUtteranceID == nil else { return nil }
        return transcripts.beginUtterance()
    }

    public mutating func transcript(
        text: String,
        isFinal: Bool,
        confidence: Double? = nil
    ) -> VoiceCaptureEvent? {
        guard session == .running else { return nil }
        guard let snapshot = transcripts.snapshot(
            text: text,
            isFinal: isFinal,
            confidence: confidence
        ) else { return nil }
        return .transcript(snapshot)
    }

    /// Converts platform speech classification into raw capture events only
    /// while transport capture is running. Semantic barge-in/silence decisions
    /// remain downstream in VoiceActivityGate.
    public mutating func activitySample(
        isSpeech: Bool,
        elapsedMilliseconds: Int64
    ) -> [VoiceCaptureEvent] {
        guard session == .running else { return [] }
        return activity.receive(
            .init(isSpeech: isSpeech, elapsedMilliseconds: elapsedMilliseconds)
        ).map(VoiceCaptureEvent.activity)
    }

    public mutating func speechEnded() -> [VoiceCaptureEvent] {
        transcripts.endUtterance()
        guard session == .running else {
            activity.reset()
            return []
        }
        return activity.endSpeech().map(VoiceCaptureEvent.activity)
    }

    public mutating func reset() {
        session = .idle
        resetCaptureRun()
    }

    private mutating func resetCaptureRun() {
        transcripts.reset()
        activity.reset()
    }
}
