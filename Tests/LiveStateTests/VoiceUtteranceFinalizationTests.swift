import XCTest
@testable import LiveState

final class VoiceUtteranceFinalizationTests: XCTestCase {
    func testFinalTranscriptWaitsForSpeechEndBeforeSubmission() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)

        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "Use server rendering", isFinal: true)),
                encounter: state
            ).isEmpty
        )
        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Use server rendering"), .userSpeechEnded]
        )
    }

    func testLaterFinalRevisionWinsWithinSameUtterance() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "Use SSR", isFinal: true)), encounter: state)
        _ = bridge.receive(.transcript(.init(text: "Use SSR for faster first paint", isFinal: true)), encounter: state)

        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Use SSR for faster first paint"), .userSpeechEnded]
        )
    }

    func testNewSpeechBoundaryAllowsSameWordsAgain() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "Yes", isFinal: true)), encounter: state)
        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Yes"), .userSpeechEnded]
        )

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "Yes", isFinal: true)), encounter: state)
        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Yes"), .userSpeechEnded]
        )
    }

    func testWhitespaceOnlyFinalNeverCommits() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)
        XCTAssertTrue(bridge.receive(.transcript(.init(text: "   ", isFinal: true)), encounter: state).isEmpty)
        XCTAssertEqual(bridge.receive(.speechEnded, encounter: state), [.userSpeechEnded])
    }

    func testMeaningfulSilenceFinalizesPendingFinalTranscript() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "A concrete example", isFinal: true)), encounter: state)

        XCTAssertEqual(
            bridge.receive(.silenceStarted, encounter: state),
            [.userSubmitted("A concrete example"), .userSilenceStarted]
        )
        XCTAssertEqual(bridge.receive(.speechEnded, encounter: state), [.userSpeechEnded])
    }

    func testSilenceDoesNotCommitPartialTranscript() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "unfinished thought", isFinal: false)), encounter: state)
        XCTAssertEqual(bridge.receive(.silenceStarted, encounter: state), [.userSilenceStarted])
        XCTAssertEqual(bridge.input.partialTranscript, "unfinished thought")
    }
    func testResetDropsPendingTranscriptAndPresentationState() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "must not leak", isFinal: true)), encounter: state)
        bridge.reset()

        XCTAssertEqual(bridge.input, VoiceInputState())
        XCTAssertEqual(bridge.receive(.speechEnded, encounter: state), [.userSpeechEnded])
    }

    func testOlderTranscriptRevisionCannotReplaceNewerFinalSnapshot() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)

        _ = bridge.receive(
            .transcript(.init(text: "Use SSR for faster first paint", isFinal: true, revision: 2)),
            encounter: state
        )
        _ = bridge.receive(
            .transcript(.init(text: "Use SSR", isFinal: true, revision: 1)),
            encounter: state
        )

        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Use SSR for faster first paint"), .userSpeechEnded]
        )
    }

    func testTranscriptRevisionRestartsAtNewSpeechBoundary() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(
            .transcript(.init(text: "First", isFinal: true, revision: 5)),
            encounter: state
        )
        _ = bridge.receive(.speechEnded, encounter: state)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(
            .transcript(.init(text: "Second", isFinal: true, revision: 0)),
            encounter: state
        )

        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Second"), .userSpeechEnded]
        )
    }

    func testLateCallbackFromClosedUtteranceCannotEnterNextUtterance() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(
            .transcript(.init(text: "First answer", isFinal: true, revision: 1, utteranceID: 41)),
            encounter: state
        )
        _ = bridge.receive(.speechEnded, encounter: state)

        _ = bridge.receive(.speechStarted, encounter: state)
        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "late first answer", isFinal: true, revision: 2, utteranceID: 41)),
                encounter: state
            ).isEmpty
        )
        _ = bridge.receive(
            .transcript(.init(text: "Second answer", isFinal: true, revision: 0, utteranceID: 42)),
            encounter: state
        )

        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Second answer"), .userSpeechEnded]
        )
    }

    func testDifferentUtteranceIdentityCannotReplaceActiveUtterance() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(
            .transcript(.init(text: "Current answer", isFinal: true, revision: 1, utteranceID: 50)),
            encounter: state
        )
        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "foreign callback", isFinal: true, revision: 9, utteranceID: 51)),
                encounter: state
            ).isEmpty
        )

        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("Current answer"), .userSpeechEnded]
        )
    }

}
