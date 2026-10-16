import XCTest
@testable import LiveState

final class VoiceActivityNormalizerTests: XCTestCase {
    func testSpeechRunEmitsMonotonicDurations() {
        var normalizer = VoiceActivityNormalizer()

        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 100)),
            [.speechBegan, .speechDuration(milliseconds: 0)]
        )
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 280)),
            [.speechDuration(milliseconds: 180)]
        )
    }

    func testSilenceDurationStartsAtFirstNonSpeechSample() {
        var normalizer = VoiceActivityNormalizer()
        _ = normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 100))

        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: false, elapsedMilliseconds: 400)),
            [.silenceDuration(milliseconds: 0)]
        )
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: false, elapsedMilliseconds: 1_300)),
            [.silenceDuration(milliseconds: 900)]
        )
    }

    func testOutOfOrderAndNegativeSamplesAreIgnored() {
        var normalizer = VoiceActivityNormalizer()
        _ = normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 200))

        XCTAssertTrue(normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 199)).isEmpty)
        XCTAssertTrue(normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: -1)).isEmpty)
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 380)),
            [.speechDuration(milliseconds: 180)]
        )
    }

    func testNonSpeechBeforeSpeechDoesNotInventActivity() {
        var normalizer = VoiceActivityNormalizer()
        XCTAssertTrue(normalizer.receive(.init(isSpeech: false, elapsedMilliseconds: 50)).isEmpty)
    }

    func testEndSpeechEmitsOnceAndClosesRun() {
        var normalizer = VoiceActivityNormalizer()
        _ = normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 10))

        XCTAssertEqual(normalizer.endSpeech(), [.speechEnded])
        XCTAssertTrue(normalizer.endSpeech().isEmpty)
    }

    func testResetAllowsFreshCaptureClock() {
        var normalizer = VoiceActivityNormalizer()
        _ = normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 5_000))
        normalizer.reset()

        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 25)),
            [.speechBegan, .speechDuration(milliseconds: 0)]
        )
    }

    func testNormalizerFeedsExistingBargeInPolicyWithoutOwningIt() {
        var normalizer = VoiceActivityNormalizer()
        var gate = VoiceActivityGate(policy: .init(bargeInMilliseconds: 180))

        for observation in normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 100)) {
            XCTAssertTrue(gate.receive(observation, counterpartIsSpeaking: true).isEmpty)
        }

        let observations = normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 280))
        let events = observations.flatMap { gate.receive($0, counterpartIsSpeaking: true) }
        XCTAssertEqual(events, [.interruptedCounterpart])
    }
}
