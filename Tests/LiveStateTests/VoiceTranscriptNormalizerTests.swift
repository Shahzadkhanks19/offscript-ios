import XCTest
@testable import LiveState

final class VoiceTranscriptNormalizerTests: XCTestCase {
    func testSnapshotRequiresActiveUtterance() {
        var normalizer = VoiceTranscriptNormalizer()
        XCTAssertNil(normalizer.snapshot(text: "stale", isFinal: false))
    }

    func testSnapshotsUseStableUtteranceIdentityAndMonotonicRevision() {
        var normalizer = VoiceTranscriptNormalizer()
        let utteranceID = normalizer.beginUtterance()

        let first = normalizer.snapshot(text: "I chose", isFinal: false)
        let second = normalizer.snapshot(text: "I chose Next.js", isFinal: true)

        XCTAssertEqual(first?.utteranceID, utteranceID)
        XCTAssertEqual(second?.utteranceID, utteranceID)
        XCTAssertEqual(first?.revision, 1)
        XCTAssertEqual(second?.revision, 2)
    }

    func testNewUtteranceChangesIdentityAndRestartsRevision() {
        var normalizer = VoiceTranscriptNormalizer()
        let firstID = normalizer.beginUtterance()
        _ = normalizer.snapshot(text: "first", isFinal: true)
        normalizer.endUtterance()

        let secondID = normalizer.beginUtterance()
        let second = normalizer.snapshot(text: "second", isFinal: false)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(second?.utteranceID, secondID)
        XCTAssertEqual(second?.revision, 1)
    }

    func testLateCallbackAfterEndIsRejected() {
        var normalizer = VoiceTranscriptNormalizer()
        _ = normalizer.beginUtterance()
        _ = normalizer.snapshot(text: "accepted", isFinal: true)
        normalizer.endUtterance()

        XCTAssertNil(normalizer.snapshot(text: "late", isFinal: true))
    }

    func testConfidenceUsesVoiceTranscriptClamping() {
        var normalizer = VoiceTranscriptNormalizer()
        _ = normalizer.beginUtterance()

        XCTAssertEqual(normalizer.snapshot(text: "high", isFinal: false, confidence: 2)?.confidence, 1)
        XCTAssertEqual(normalizer.snapshot(text: "low", isFinal: false, confidence: -1)?.confidence, 0)
    }

    func testResetPreventsPreviousSessionCallbacksAndRestartsIdentity() {
        var normalizer = VoiceTranscriptNormalizer()
        XCTAssertEqual(normalizer.beginUtterance(), 1)
        _ = normalizer.snapshot(text: "old", isFinal: false)
        normalizer.reset()

        XCTAssertNil(normalizer.snapshot(text: "stale", isFinal: true))
        XCTAssertEqual(normalizer.beginUtterance(), 1)
        XCTAssertEqual(normalizer.snapshot(text: "new", isFinal: false)?.revision, 1)
    }
}
