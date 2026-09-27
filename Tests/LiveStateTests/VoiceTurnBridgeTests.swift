import XCTest
@testable import LiveState

final class VoiceTurnBridgeTests: XCTestCase {
    func testPartialTranscriptNeverCreatesAuthoritativeUserTurn() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        let events = bridge.receive(
            .transcript(.init(text: "still speaking", isFinal: false)),
            encounter: state
        )

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(bridge.input.partialTranscript, "still speaking")
    }

    func testFinalTranscriptBecomesUserSubmission() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        let events = bridge.receive(
            .transcript(.init(text: "  We chose SSR.  ", isFinal: true)),
            encounter: state
        )

        XCTAssertEqual(events, [.userSubmitted("We chose SSR.")])
    }

    func testBargeInWhileCounterpartSpeaksProducesOrderedEvents() {
        var state = EncounterState(lifecycle: .active)
        state.conversation.turnState = .counterpartSpeaking
        var bridge = VoiceTurnBridge()

        XCTAssertEqual(
            bridge.receive(.interruptedCounterpart, encounter: state),
            [.counterpartInterrupted, .userSpeechStarted]
        )
    }

    func testVoiceCallbacksAreIgnoredOutsideActiveEncounter() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .paused)

        XCTAssertTrue(bridge.receive(.speechStarted, encounter: state).isEmpty)
    }

    func testVoiceTurnEventsDriveDeterministicTurnState() {
        var state = EncounterState(lifecycle: .active)
        state.conversation.turnState = .counterpartSpeaking

        state = LiveStateReducer.reduce(state: state, event: .counterpartInterrupted).state
        XCTAssertEqual(state.conversation.turnState, .overlap)
        XCTAssertEqual(state.user.interruptions, 1)

        state = LiveStateReducer.reduce(state: state, event: .userSpeechStarted).state
        XCTAssertEqual(state.conversation.turnState, .userSpeaking)

        state = LiveStateReducer.reduce(state: state, event: .userSilenceStarted).state
        XCTAssertEqual(state.conversation.turnState, .silence)
    }
}
