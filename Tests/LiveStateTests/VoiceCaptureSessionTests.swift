import XCTest
@testable import LiveState

final class VoiceCaptureSessionTests: XCTestCase {
    func testPermissionLifecycleDoesNotInventRunningCapture() {
        var state = VoiceCaptureSessionState.idle
        state = VoiceCaptureSessionReducer.reduce(state: state, event: .permissionRequestStarted)
        XCTAssertEqual(state, .requestingPermission)
        state = VoiceCaptureSessionReducer.reduce(state: state, event: .permissionGranted)
        XCTAssertEqual(state, .idle)
    }

    func testCaptureRequiresExplicitStartAndStartedEvents() {
        var state = VoiceCaptureSessionState.idle
        state = VoiceCaptureSessionReducer.reduce(state: state, event: .startRequested)
        XCTAssertEqual(state, .starting)
        state = VoiceCaptureSessionReducer.reduce(state: state, event: .captureStarted)
        XCTAssertEqual(state, .running)
    }

    func testInterruptionCanRecoverOrStop() {
        var state = VoiceCaptureSessionState.running
        state = VoiceCaptureSessionReducer.reduce(state: state, event: .interruptionBegan)
        XCTAssertEqual(state, .interrupted)
        state = VoiceCaptureSessionReducer.reduce(
            state: state,
            event: .interruptionEnded(shouldResume: true)
        )
        XCTAssertEqual(state, .recovering)
        state = VoiceCaptureSessionReducer.reduce(state: state, event: .recoverySucceeded)
        XCTAssertEqual(state, .running)

        state = VoiceCaptureSessionReducer.reduce(state: state, event: .interruptionBegan)
        state = VoiceCaptureSessionReducer.reduce(
            state: state,
            event: .interruptionEnded(shouldResume: false)
        )
        XCTAssertEqual(state, .stopped)
    }

    func testRouteChangeMovesRunningCaptureIntoRecovery() {
        let state = VoiceCaptureSessionReducer.reduce(state: .running, event: .routeChanged)
        XCTAssertEqual(state, .recovering)
    }

    func testFailuresAreExplicitTransportState() {
        XCTAssertEqual(
            VoiceCaptureSessionReducer.reduce(state: .idle, event: .permissionDenied),
            .failed(.permissionDenied)
        )
        XCTAssertEqual(
            VoiceCaptureSessionReducer.reduce(state: .running, event: .streamFailed),
            .failed(.streamFailed)
        )
        XCTAssertEqual(
            VoiceCaptureSessionReducer.reduce(state: .recovering, event: .recoveryFailed),
            .failed(.recoveryFailed)
        )
    }

    func testStopIsIdempotentAtStateBoundary() {
        var state = VoiceCaptureSessionReducer.reduce(state: .running, event: .stopRequested)
        XCTAssertEqual(state, .stopped)
        state = VoiceCaptureSessionReducer.reduce(state: state, event: .stopRequested)
        XCTAssertEqual(state, .stopped)
    }

    func testCaptureSessionStateRoundTripsThroughPersistenceEncoding() throws {
        let original = VoiceCaptureSessionState.failed(.configurationFailed)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoiceCaptureSessionState.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
