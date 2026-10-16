import XCTest
@testable import LiveState

final class VoiceCaptureAdapterMachineTests: XCTestCase {
    private func runningMachine() -> VoiceCaptureAdapterMachine {
        var machine = VoiceCaptureAdapterMachine()
        _ = machine.receive(.session(.startRequested))
        _ = machine.receive(.session(.captureStarted))
        return machine
    }

    func testSpeechBoundaryAutomaticallyOpensTranscriptIdentity() {
        var machine = runningMachine()

        let activity = machine.receive(
            .activity(.init(isSpeech: true, elapsedMilliseconds: 100))
        )
        XCTAssertEqual(
            activity.events,
            [.activity(.speechBegan), .activity(.speechDuration(milliseconds: 0))]
        )

        let transcript = machine.receive(
            .transcript(text: "Hello", isFinal: false, confidence: nil)
        )
        guard case let .transcript(snapshot)? = transcript.events.first else {
            return XCTFail("Expected normalized transcript")
        }
        XCTAssertEqual(snapshot.utteranceID, 1)
        XCTAssertEqual(snapshot.revision, 1)
    }

    func testTranscriptWithoutPhysicalSpeechBoundaryIsRejected() {
        var machine = runningMachine()
        let output = machine.receive(
            .transcript(text: "stale", isFinal: true, confidence: nil)
        )
        XCTAssertTrue(output.events.isEmpty)
    }

    func testSpeechEndClosesBothActivityAndTranscriptRun() {
        var machine = runningMachine()
        _ = machine.receive(.activity(.init(isSpeech: true, elapsedMilliseconds: 10)))
        _ = machine.receive(.transcript(text: "done", isFinal: true, confidence: nil))

        XCTAssertEqual(machine.receive(.speechEnded).events, [.activity(.speechEnded)])
        XCTAssertTrue(
            machine.receive(.transcript(text: "late", isFinal: true, confidence: nil)).events.isEmpty
        )
    }

    func testRouteChangeReturnsRecoveryActionAndInvalidatesOldCallbacks() {
        var machine = runningMachine()
        _ = machine.receive(.activity(.init(isSpeech: true, elapsedMilliseconds: 1_000)))

        let output = machine.receive(.session(.routeChanged))
        XCTAssertEqual(output.recoveryAction, .restartCapture)
        XCTAssertTrue(output.events.isEmpty)
        XCTAssertTrue(
            machine.receive(.transcript(text: "late", isFinal: true, confidence: nil)).events.isEmpty
        )
    }

    func testRecoveryCreatesFreshCaptureRun() {
        var machine = runningMachine()
        _ = machine.receive(.activity(.init(isSpeech: true, elapsedMilliseconds: 5_000)))
        _ = machine.receive(.session(.routeChanged))
        _ = machine.receive(.session(.recoverySucceeded))

        let activity = machine.receive(
            .activity(.init(isSpeech: true, elapsedMilliseconds: 25))
        )
        XCTAssertEqual(
            activity.events,
            [.activity(.speechBegan), .activity(.speechDuration(milliseconds: 0))]
        )

        let transcript = machine.receive(
            .transcript(text: "fresh", isFinal: false, confidence: nil)
        )
        guard case let .transcript(snapshot)? = transcript.events.first else {
            return XCTFail("Expected fresh transcript")
        }
        XCTAssertEqual(snapshot.utteranceID, 1)
        XCTAssertEqual(snapshot.revision, 1)
    }

    func testMachineDoesNotProduceSemanticBargeInEvents() {
        var machine = runningMachine()
        _ = machine.receive(.activity(.init(isSpeech: true, elapsedMilliseconds: 100)))
        let output = machine.receive(
            .activity(.init(isSpeech: true, elapsedMilliseconds: 400))
        )

        XCTAssertEqual(output.events, [.activity(.speechDuration(milliseconds: 300))])
    }
}
