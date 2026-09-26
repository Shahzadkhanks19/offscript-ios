import Foundation

/// Raw/observable measurements only. These types deliberately avoid inferred
/// psychology such as confidence, anxiety, honesty, personality, or intent.
public enum ObservableSignal: Equatable, Sendable, Codable {
    case speech(SpeechObservation)
    case turn(TurnObservation)
    case visual(VisualObservation)
}

public struct SpeechObservation: Equatable, Sendable, Codable {
    public var wordsPerMinute: Double?
    public var pauseCount: Int
    public var longestPauseSeconds: Double?
    public init(wordsPerMinute: Double? = nil, pauseCount: Int = 0, longestPauseSeconds: Double? = nil) {
        self.wordsPerMinute = wordsPerMinute
        self.pauseCount = max(0, pauseCount)
        self.longestPauseSeconds = longestPauseSeconds.map { max(0, $0) }
    }
}

public struct TurnObservation: Equatable, Sendable, Codable {
    public var interruptedCounterpart: Bool
    public var wasInterrupted: Bool
    public var durationSeconds: Double?
    public init(interruptedCounterpart: Bool = false, wasInterrupted: Bool = false, durationSeconds: Double? = nil) {
        self.interruptedCounterpart = interruptedCounterpart
        self.wasInterrupted = wasInterrupted
        self.durationSeconds = durationSeconds.map { max(0, $0) }
    }
}

public struct VisualObservation: Equatable, Sendable, Codable {
    public var facePresent: Bool?
    public var lookingAtNotes: Bool?
    public var framingStable: Bool?
    public init(facePresent: Bool? = nil, lookingAtNotes: Bool? = nil, framingStable: Bool? = nil) {
        self.facePresent = facePresent
        self.lookingAtNotes = lookingAtNotes
        self.framingStable = framingStable
    }
}
