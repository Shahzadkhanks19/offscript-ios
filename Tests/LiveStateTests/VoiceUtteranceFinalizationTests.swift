import XCTest
@testable import LiveState

final class VoiceUtteranceFinalizationTests: XCTestCase {
    func testDuplicateFinalTranscriptWithinUtteranceSubmitsOnce() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)
        let first = bridge.receive(.transcript(.init(text: "Use server rendering", isFinal: true)), encounter: state)
        let duplicate = bridge.receive(.transcript(.init(text: "Use server rendering", isFinal: true)), encounter: state)
        XCTAssertEqual(first, [.userSubmitted("Use server rendering")])
        XCTAssertTrue(duplicate.isEmpty)
    }

    func testNewSpeechBoundaryAllowsSameWordsAgain() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.transcript(.init(text: "Yes", isFinal: true)), encounter: state)
        _ = bridge.receive(.speechEnded, encounter: state)
        _ = bridge.receive(.speechStarted, encounter: state)
        XCTAssertEqual(bridge.receive(.transcript(.init(text: "Yes", isFinal: true)), encounter: state), [.userSubmitted("Yes")])
    }

    func testWhitespaceOnlyFinalNeverCommits() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        XCTAssertTrue(bridge.receive(.transcript(.init(text: "   ", isFinal: true)), encounter: state).isEmpty)
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
