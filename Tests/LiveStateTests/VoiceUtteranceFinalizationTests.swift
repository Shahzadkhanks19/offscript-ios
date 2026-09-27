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

    func testSilenceDoesNotCommitPartialTranscript() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "unfinished thought", isFinal: false)), encounter: state)
        XCTAssertEqual(bridge.receive(.silenceStarted, encounter: state), [.userSilenceStarted])
        XCTAssertEqual(bridge.input.partialTranscript, "unfinished thought")
    }
}
