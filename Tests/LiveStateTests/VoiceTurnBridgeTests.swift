import XCTest
@testable import LiveState

final class VoiceTurnBridgeTests: XCTestCase {
    func testPartialTranscriptNeverCreatesAuthoritativeUserTurn() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)
        _ = bridge.receive(.speechStarted, encounter: state)

        let events = bridge.receive(
            .transcript(.init(text: "still speaking", isFinal: false)),
            encounter: state
        )

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(bridge.input.partialTranscript, "still speaking")
    }

    func testFinalTranscriptBecomesUserSubmissionAtSpeechEnd() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "  We chose SSR.  ", isFinal: true)),
                encounter: state
            ).isEmpty
        )

        XCTAssertEqual(
            bridge.receive(.speechEnded, encounter: state),
            [.userSubmitted("We chose SSR."), .userSpeechEnded]
        )
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

    func testTranscriptBeforeSpeechStartIsIgnoredWithoutPresentationMutation() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "stale", isFinal: true, revision: 1, utteranceID: 7)),
                encounter: state
            ).isEmpty
        )
        XCTAssertEqual(bridge.input, VoiceInputState())
    }

    func testLateFinalAfterSpeechEndIsIgnored() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(
            .transcript(.init(text: "accepted", isFinal: true, revision: 1, utteranceID: 8)),
            encounter: state
        )
        _ = bridge.receive(.speechEnded, encounter: state)
        let inputAfterEnd = bridge.input

        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "late", isFinal: true, revision: 2, utteranceID: 8)),
                encounter: state
            ).isEmpty
        )
        XCTAssertEqual(bridge.input, inputAfterEnd)
    }

    func testLateFinalAfterSilenceIsIgnored() {
        var bridge = VoiceTurnBridge()
        let state = EncounterState(lifecycle: .active)

        _ = bridge.receive(.speechStarted, encounter: state)
        _ = bridge.receive(.silenceStarted, encounter: state)
        let inputAfterSilence = bridge.input

        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "late", isFinal: true, revision: 1, utteranceID: 9)),
                encounter: state
            ).isEmpty
        )
        XCTAssertEqual(bridge.input, inputAfterSilence)
    }

    func testBargeInEstablishesActiveUtteranceForTranscript() {
        var state = EncounterState(lifecycle: .active)
        state.conversation.turnState = .counterpartSpeaking
        var bridge = VoiceTurnBridge()

        _ = bridge.receive(.interruptedCounterpart, encounter: state)
        XCTAssertTrue(
            bridge.receive(
                .transcript(.init(text: "my interruption", isFinal: false, revision: 1, utteranceID: 10)),
                encounter: state
            ).isEmpty
        )
        XCTAssertEqual(bridge.input.partialTranscript, "my interruption")
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
