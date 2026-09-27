import XCTest
@testable import LiveState

final class VoiceActivityGateTests: XCTestCase {
    func testSpeechStartEmitsOncePerContinuousRun() {
        var gate = VoiceActivityGate()
        XCTAssertEqual(gate.receive(.speechBegan, counterpartIsSpeaking: false), [.speechStarted])
        XCTAssertTrue(gate.receive(.speechBegan, counterpartIsSpeaking: false).isEmpty)
        XCTAssertEqual(gate.receive(.speechEnded, counterpartIsSpeaking: false), [.speechEnded])
        XCTAssertEqual(gate.receive(.speechBegan, counterpartIsSpeaking: false), [.speechStarted])
    }

    func testShortSilenceIsSuppressedUntilThreshold() {
        var gate = VoiceActivityGate(policy: .init(meaningfulSilenceMilliseconds: 900))
        _ = gate.receive(.speechBegan, counterpartIsSpeaking: false)
        XCTAssertTrue(gate.receive(.silenceDuration(milliseconds: 899), counterpartIsSpeaking: false).isEmpty)
        XCTAssertEqual(gate.receive(.silenceDuration(milliseconds: 900), counterpartIsSpeaking: false), [.silenceStarted])
        XCTAssertTrue(gate.receive(.silenceDuration(milliseconds: 1200), counterpartIsSpeaking: false).isEmpty)
    }

    func testBargeInRequiresSustainedSpeechAndEmitsOnce() {
        var gate = VoiceActivityGate(policy: .init(bargeInMilliseconds: 180))
        _ = gate.receive(.speechBegan, counterpartIsSpeaking: true)
        XCTAssertTrue(gate.receive(.speechDuration(milliseconds: 179), counterpartIsSpeaking: true).isEmpty)
        XCTAssertEqual(gate.receive(.speechDuration(milliseconds: 180), counterpartIsSpeaking: true), [.interruptedCounterpart])
        XCTAssertTrue(gate.receive(.speechDuration(milliseconds: 300), counterpartIsSpeaking: true).isEmpty)
    }

    func testPotentialBargeInDoesNotStealTurnBeforeThreshold() {
        var gate = VoiceActivityGate(policy: .init(bargeInMilliseconds: 180))
        XCTAssertTrue(gate.receive(.speechBegan, counterpartIsSpeaking: true).isEmpty)
        XCTAssertTrue(gate.receive(.speechDuration(milliseconds: 179), counterpartIsSpeaking: true).isEmpty)
        XCTAssertTrue(gate.receive(.speechEnded, counterpartIsSpeaking: true).isEmpty)
    }

    func testSpeechDoesNotBecomeBargeInWhenCounterpartIsNotSpeaking() {
        var gate = VoiceActivityGate(policy: .init(bargeInMilliseconds: 180))
        _ = gate.receive(.speechBegan, counterpartIsSpeaking: false)
        XCTAssertTrue(gate.receive(.speechDuration(milliseconds: 500), counterpartIsSpeaking: false).isEmpty)
    }

    func testSpeechResetsPreviousSilenceGate() {
        var gate = VoiceActivityGate(policy: .init(meaningfulSilenceMilliseconds: 100))
        _ = gate.receive(.silenceDuration(milliseconds: 100), counterpartIsSpeaking: false)
        XCTAssertTrue(gate.receive(.silenceDuration(milliseconds: 200), counterpartIsSpeaking: false).isEmpty)
        _ = gate.receive(.speechBegan, counterpartIsSpeaking: false)
        XCTAssertEqual(gate.receive(.silenceDuration(milliseconds: 100), counterpartIsSpeaking: false), [.silenceStarted])
    }
}
