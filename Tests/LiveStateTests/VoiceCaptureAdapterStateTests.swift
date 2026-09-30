import XCTest
@testable import LiveState

final class VoiceCaptureAdapterStateTests: XCTestCase {
    private func runningState() -> VoiceCaptureAdapterState {
        var state = VoiceCaptureAdapterState()
        _ = state.receive(.startRequested)
        _ = state.receive(.captureStarted)
        return state
    }

    func testTranscriptCannotBeginBeforeCaptureRuns() {
        var state = VoiceCaptureAdapterState()
        XCTAssertNil(state.speechBegan())
        XCTAssertNil(state.transcript(text: "ignored", isFinal: false))
    }

    func testRunningCaptureProducesNormalizedTranscriptEvent() {
        var state = runningState()
        let utteranceID = state.speechBegan()
        let event = state.transcript(text: "Hello", isFinal: false, confidence: 0.8)

        guard case let .transcript(transcript)? = event else {
            return XCTFail("Expected transcript capture event")
        }
        XCTAssertEqual(transcript.utteranceID, utteranceID)
        XCTAssertEqual(transcript.revision, 1)
        XCTAssertEqual(transcript.text, "Hello")
    }

    func testDuplicateSpeechBoundaryDoesNotReplaceActiveIdentity() {
        var state = runningState()
        let first = state.speechBegan()
        XCTAssertNil(state.speechBegan())
        XCTAssertEqual(state.transcripts.activeUtteranceID, first)
    }

    func testInterruptionInvalidatesUtteranceAndRequestsRecovery() {
        var state = runningState()
        _ = state.speechBegan()
        _ = state.transcript(text: "before interruption", isFinal: false)

        _ = state.receive(.interruptionBegan)
        XCTAssertNil(state.transcripts.activeUtteranceID)
        XCTAssertNil(state.transcript(text: "late", isFinal: true))

        let action = state.receive(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(action, .restartCapture)
        XCTAssertEqual(state.session, .recovering)
    }

    func testRouteChangeInvalidatesUtteranceAndRequestsRestart() {
        var state = runningState()
        _ = state.speechBegan()

        let action = state.receive(.routeChanged)

        XCTAssertEqual(action, .restartCapture)
        XCTAssertEqual(state.session, .recovering)
        XCTAssertNil(state.transcripts.activeUtteranceID)
    }

    func testRecoveryStartsWithFreshUtteranceIdentity() {
        var state = runningState()
        XCTAssertEqual(state.speechBegan(), 1)
        _ = state.receive(.routeChanged)
        _ = state.receive(.recoverySucceeded)

        XCTAssertEqual(state.session, .running)
        XCTAssertEqual(state.speechBegan(), 1)
    }

    func testStopRejectsLateTranscriptionCallbacks() {
        var state = runningState()
        _ = state.speechBegan()
        _ = state.receive(.stopRequested)

        XCTAssertEqual(state.session, .stopped)
        XCTAssertNil(state.transcript(text: "late", isFinal: true))
    }

    func testResetReturnsAdapterBoundaryToCleanIdleState() {
        var state = runningState()
        _ = state.speechBegan()
        state.reset()

        XCTAssertEqual(state.session, .idle)
        XCTAssertNil(state.transcripts.activeUtteranceID)
        XCTAssertNil(state.transcript(text: "stale", isFinal: false))
    }
}
