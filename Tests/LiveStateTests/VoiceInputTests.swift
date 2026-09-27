import XCTest
@testable import LiveState

final class VoiceInputTests: XCTestCase {
    func testPartialTranscriptDoesNotBecomeFinalUtterance() {
        var state = VoiceInputState()
        state = VoiceInputReducer.reduce(state: state, event: .speechStarted)
        state = VoiceInputReducer.reduce(
            state: state,
            event: .transcript(.init(text: "I chose Next", isFinal: false))
        )

        XCTAssertTrue(state.isCapturing)
        XCTAssertEqual(state.partialTranscript, "I chose Next")
        XCTAssertNil(state.lastFinalTranscript)
    }

    func testFinalTranscriptClearsPartialAndPreservesUtterance() {
        var state = VoiceInputState(partialTranscript: "I chose Next")
        state = VoiceInputReducer.reduce(
            state: state,
            event: .transcript(.init(text: "I chose Next.js for SSR.", isFinal: true))
        )

        XCTAssertEqual(state.partialTranscript, "")
        XCTAssertEqual(state.lastFinalTranscript, "I chose Next.js for SSR.")
    }

    func testSilenceIsExplicitVoiceState() {
        let state = VoiceInputReducer.reduce(
            state: .init(isCapturing: true, partialTranscript: "unfinished"),
            event: .silenceStarted
        )

        XCTAssertFalse(state.isCapturing)
        XCTAssertTrue(state.isSilent)
        XCTAssertEqual(state.partialTranscript, "unfinished")
    }

    func testBargeInMarksCaptureActiveWithoutInventingTranscript() {
        let state = VoiceInputReducer.reduce(
            state: .init(),
            event: .interruptedCounterpart
        )

        XCTAssertTrue(state.isCapturing)
        XCTAssertFalse(state.isSilent)
        XCTAssertTrue(state.partialTranscript.isEmpty)
        XCTAssertNil(state.lastFinalTranscript)
    }

    func testTranscriptConfidenceIsClamped() {
        XCTAssertEqual(VoiceTranscript(text: "high", isFinal: true, confidence: 1.5).confidence, 1)
        XCTAssertEqual(VoiceTranscript(text: "low", isFinal: true, confidence: -0.2).confidence, 0)
    }

    func testVoiceEventsRoundTripThroughPersistenceEncoding() throws {
        let original = VoiceInputEvent.transcript(
            .init(text: "A durable transcript", isFinal: true, confidence: 0.91)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoiceInputEvent.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
