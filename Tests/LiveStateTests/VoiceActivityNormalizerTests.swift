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

    func testResumedSpeechResetsCandidateSilenceTimer() {
        var normalizer = VoiceActivityNormalizer()
        _ = normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 100))
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: false, elapsedMilliseconds: 400)),
            [.silenceDuration(milliseconds: 0)]
        )
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: false, elapsedMilliseconds: 700)),
            [.silenceDuration(milliseconds: 300)]
        )

        // The user resumes speaking before meaningful silence is reached.
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: true, elapsedMilliseconds: 750)),
            [.speechDuration(milliseconds: 650)]
        )

        // A later pause is a new candidate silence, not a continuation of the
        // pause that began at 400 ms.
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: false, elapsedMilliseconds: 900)),
            [.silenceDuration(milliseconds: 0)]
        )
        XCTAssertEqual(
            normalizer.receive(.init(isSpeech: false, elapsedMilliseconds: 1_100)),
            [.silenceDuration(milliseconds: 200)]
        )
    }

    func testResumedSpeechPreventsOldPauseFromTriggeringMeaningfulSilence() {
        var normalizer = VoiceActivityNormalizer()
        var gate = VoiceActivityGate(policy: .init(meaningfulSilenceMilliseconds: 900))

        func semanticEvents(
            _ sample: VoiceActivitySample,
            normalizer: inout VoiceActivityNormalizer,
            gate: inout VoiceActivityGate
        ) -> [VoiceCaptureEvent] {
            normalizer.receive(sample).flatMap {
                gate.receive($0, counterpartIsSpeaking: false)
            }
        }

        _ = semanticEvents(
            .init(isSpeech: true, elapsedMilliseconds: 0),
            normalizer: &normalizer,
            gate: &gate
        )
        XCTAssertTrue(
            semanticEvents(
                .init(isSpeech: false, elapsedMilliseconds: 100),
                normalizer: &normalizer,
                gate: &gate
            ).isEmpty
        )
        _ = semanticEvents(
            .init(isSpeech: true, elapsedMilliseconds: 500),
            normalizer: &normalizer,
            gate: &gate
        )

        XCTAssertTrue(
            semanticEvents(
                .init(isSpeech: false, elapsedMilliseconds: 950),
                normalizer: &normalizer,
                gate: &gate
            ).isEmpty
        )
        XCTAssertTrue(
            semanticEvents(
                .init(isSpeech: false, elapsedMilliseconds: 1_300),
                normalizer: &normalizer,
                gate: &gate
            ).isEmpty
        )
        XCTAssertEqual(
            semanticEvents(
                .init(isSpeech: false, elapsedMilliseconds: 1_850),
                normalizer: &normalizer,
                gate: &gate
            ),
            [.silenceStarted]
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
