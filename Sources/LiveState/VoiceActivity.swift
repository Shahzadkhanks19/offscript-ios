import Foundation

/// Monotonic timing policy for voice activity. Platform adapters provide
/// elapsed milliseconds from their own monotonic audio clock; wall time is
/// deliberately excluded from LiveState.
public struct VoiceActivityPolicy: Equatable, Sendable, Codable {
    public var meaningfulSilenceMilliseconds: Int64
    public var bargeInMilliseconds: Int64

    public init(
        meaningfulSilenceMilliseconds: Int64 = 900,
        bargeInMilliseconds: Int64 = 180
    ) {
        self.meaningfulSilenceMilliseconds = max(0, meaningfulSilenceMilliseconds)
        self.bargeInMilliseconds = max(0, bargeInMilliseconds)
    }
}

public enum VoiceActivityDecision: Equatable, Sendable {
    case none
    case meaningfulSilence
    case bargeIn
}

public enum VoiceActivityEngine {
    public static func silenceDecision(
        durationMilliseconds: Int64,
        policy: VoiceActivityPolicy
    ) -> VoiceActivityDecision {
        guard durationMilliseconds >= 0 else { return .none }
        return durationMilliseconds >= policy.meaningfulSilenceMilliseconds
            ? .meaningfulSilence
            : .none
    }

    public static func speechDecision(
        durationMilliseconds: Int64,
        counterpartIsSpeaking: Bool,
        policy: VoiceActivityPolicy
    ) -> VoiceActivityDecision {
        guard counterpartIsSpeaking, durationMilliseconds >= 0 else { return .none }
        return durationMilliseconds >= policy.bargeInMilliseconds ? .bargeIn : .none
    }
}
