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

    func testBeginGenerationInvalidatesPreviousCallbackOwnership() {
        var machine = VoiceCaptureAdapterMachine()
        let first = machine.beginGeneration()
        _ = machine.receive(.session(.startRequested), generation: first)
        _ = machine.receive(.session(.captureStarted), generation: first)
        let second = machine.beginGeneration()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(machine.state.session, .idle)
        XCTAssertTrue(
            machine.receive(
                .activity(.init(isSpeech: true, elapsedMilliseconds: 100)),
                generation: first
            ).events.isEmpty
        )
        XCTAssertEqual(machine.state.session, .idle)
    }

    func testOldTranscriptCannotEnterNewUtteranceWithReusedLocalID() {
        var machine = VoiceCaptureAdapterMachine()
        let first = machine.beginGeneration()
        _ = machine.receive(.session(.startRequested), generation: first)
        _ = machine.receive(.session(.captureStarted), generation: first)
        _ = machine.receive(
            .activity(.init(isSpeech: true, elapsedMilliseconds: 100)),
            generation: first
        )

        let second = machine.beginGeneration()
        _ = machine.receive(.session(.startRequested), generation: second)
        _ = machine.receive(.session(.captureStarted), generation: second)
        _ = machine.receive(
            .activity(.init(isSpeech: true, elapsedMilliseconds: 25)),
            generation: second
        )

        let stale = machine.receive(
            .transcript(text: "old callback", isFinal: true, confidence: nil),
            generation: first
        )
        XCTAssertTrue(stale.events.isEmpty)

        let current = machine.receive(
            .transcript(text: "current callback", isFinal: false, confidence: nil),
            generation: second
        )
        guard case let .transcript(snapshot)? = current.events.first else {
            return XCTFail("Expected current generation transcript")
        }
        XCTAssertEqual(snapshot.utteranceID, 1)
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(snapshot.text, "current callback")
    }

    func testOldSessionFailureCannotPoisonNewGeneration() {
        var machine = VoiceCaptureAdapterMachine()
        let first = machine.beginGeneration()
        let second = machine.beginGeneration()
        _ = machine.receive(.session(.startRequested), generation: second)
        _ = machine.receive(.session(.captureStarted), generation: second)

        _ = machine.receive(.session(.streamFailed), generation: first)

        XCTAssertEqual(machine.state.session, .running)
    }

    func testResetInvalidatesOutstandingGenerationToken() {
        var machine = VoiceCaptureAdapterMachine()
        let generation = machine.beginGeneration()
        machine.reset()

        _ = machine.receive(.session(.streamFailed), generation: generation)

        XCTAssertEqual(machine.state.session, .idle)
        XCTAssertNotEqual(machine.generation, generation)
    }
}
