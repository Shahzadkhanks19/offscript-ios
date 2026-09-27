import XCTest
@testable import LiveState

final class VoiceActivityPolicyTests: XCTestCase {
    func testShortPauseIsNotMeaningfulSilence() {
        let policy = VoiceActivityPolicy(meaningfulSilenceMilliseconds: 900)
        XCTAssertEqual(
            VoiceActivityEngine.silenceDecision(durationMilliseconds: 899, policy: policy),
            .none
        )
    }

    func testSilenceThresholdIsInclusive() {
        let policy = VoiceActivityPolicy(meaningfulSilenceMilliseconds: 900)
        XCTAssertEqual(
            VoiceActivityEngine.silenceDecision(durationMilliseconds: 900, policy: policy),
            .meaningfulSilence
        )
    }

    func testBargeInRequiresCounterpartAndThreshold() {
        let policy = VoiceActivityPolicy(bargeInMilliseconds: 180)
        XCTAssertEqual(
            VoiceActivityEngine.speechDecision(durationMilliseconds: 179, counterpartIsSpeaking: true, policy: policy),
            .none
        )
        XCTAssertEqual(
            VoiceActivityEngine.speechDecision(durationMilliseconds: 180, counterpartIsSpeaking: true, policy: policy),
            .bargeIn
        )
        XCTAssertEqual(
            VoiceActivityEngine.speechDecision(durationMilliseconds: 500, counterpartIsSpeaking: false, policy: policy),
            .none
        )
    }

    func testNegativeDurationsAreRejectedAsNoDecision() {
        let policy = VoiceActivityPolicy()
        XCTAssertEqual(VoiceActivityEngine.silenceDecision(durationMilliseconds: -1, policy: policy), .none)
        XCTAssertEqual(
            VoiceActivityEngine.speechDecision(durationMilliseconds: -1, counterpartIsSpeaking: true, policy: policy),
            .none
        )
    }

    func testPolicyClampsNegativeThresholds() {
        let policy = VoiceActivityPolicy(
            meaningfulSilenceMilliseconds: -10,
            bargeInMilliseconds: -20
        )
        XCTAssertEqual(policy.meaningfulSilenceMilliseconds, 0)
        XCTAssertEqual(policy.bargeInMilliseconds, 0)
    }
}
