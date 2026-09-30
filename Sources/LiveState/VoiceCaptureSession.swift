import Foundation

/// Platform-independent lifecycle reported by a realtime voice capture adapter.
/// Apple-specific permission, AVAudioSession, interruption, and route callbacks
/// are translated into these values outside LiveState.
public enum VoiceCaptureSessionState: Equatable, Sendable, Codable {
    case idle
    case requestingPermission
    case starting
    case running
    case interrupted
    case recovering
    case stopped
    case failed(VoiceCaptureFailure)
}

public enum VoiceCaptureFailure: Equatable, Sendable, Codable {
    case permissionDenied
    case permissionRestricted
    case unavailable
    case configurationFailed
    case streamFailed
    case recoveryFailed
}

/// Hardware/framework conditions that can affect capture without becoming
/// semantic conversation events.
public enum VoiceCaptureSessionEvent: Equatable, Sendable, Codable {
    case permissionRequestStarted
    case permissionGranted
    case permissionDenied
    case permissionRestricted
    case startRequested
    case captureStarted
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
    case recoverySucceeded
    case recoveryFailed
    case streamFailed
    case stopRequested
}

/// Deterministic adapter-facing lifecycle reducer. It models transport state
/// only; EncounterState and conversational turn ownership remain in LiveState.
public enum VoiceCaptureSessionReducer {
    public static func reduce(
        state: VoiceCaptureSessionState,
        event: VoiceCaptureSessionEvent
    ) -> VoiceCaptureSessionState {
        switch event {
        case .permissionRequestStarted:
            return .requestingPermission
        case .permissionGranted:
            return state == .requestingPermission ? .idle : state
        case .permissionDenied:
            return .failed(.permissionDenied)
        case .permissionRestricted:
            return .failed(.permissionRestricted)
        case .startRequested:
            switch state {
            case .idle, .stopped, .recovering:
                return .starting
            default:
                return state
            }
        case .captureStarted:
            return state == .starting || state == .recovering ? .running : state
        case .interruptionBegan:
            return state == .running ? .interrupted : state
        case let .interruptionEnded(shouldResume):
            guard state == .interrupted else { return state }
            return shouldResume ? .recovering : .stopped
        case .routeChanged:
            return state == .running ? .recovering : state
        case .recoverySucceeded:
            return state == .recovering ? .running : state
        case .recoveryFailed:
            return .failed(.recoveryFailed)
        case .streamFailed:
            return .failed(.streamFailed)
        case .stopRequested:
            return .stopped
        }
    }
}


/// Recovery decision kept separate from platform mechanics so adapters can map
/// AVAudioSession callbacks into deterministic behavior before touching
/// hardware again.
public enum VoiceCaptureRecoveryAction: Equatable, Sendable {
    case none
    case restartCapture
    case stopCapture
    case fail(VoiceCaptureFailure)
}

public enum VoiceCaptureRecoveryPolicy {
    public static func action(
        state: VoiceCaptureSessionState,
        event: VoiceCaptureSessionEvent
    ) -> VoiceCaptureRecoveryAction {
        switch (state, event) {
        case (.interrupted, .interruptionEnded(shouldResume: true)):
            return .restartCapture
        case (.interrupted, .interruptionEnded(shouldResume: false)):
            return .stopCapture
        case (.running, .routeChanged):
            return .restartCapture
        case (_, .permissionDenied):
            return .fail(.permissionDenied)
        case (_, .permissionRestricted):
            return .fail(.permissionRestricted)
        case (_, .streamFailed):
            return .fail(.streamFailed)
        case (.recovering, .recoveryFailed):
            return .fail(.recoveryFailed)
        default:
            return .none
        }
    }
}
