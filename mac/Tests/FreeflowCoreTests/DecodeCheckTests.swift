import FreeflowCore
import XCTest

/// When a Parakeet pass counts as failed and gets retried (values from the
/// failing benchmark windows: good decodes 0.78-1.00 mean confidence, the
/// garbage loops 0.14-0.16).
final class DecodeCheckTests: XCTestCase {
    private let speech = [Float](repeating: 0.05, count: 16000)
    private let silence = [Float](repeating: 0, count: 16000)

    func testBlankOnSpeechFailed() {
        XCTAssertTrue(DecodeCheck.failed(confidences: [], audio: speech))
    }

    func testBlankOnSilenceIsJustSilence() {
        XCTAssertFalse(DecodeCheck.failed(confidences: [], audio: silence))
        XCTAssertFalse(DecodeCheck.failed(confidences: [], audio: Array(speech.prefix(4000))))   // too short to judge
    }

    func testLowConfidenceLoopFailed() {
        XCTAssertTrue(DecodeCheck.failed(confidences: [0.15, 0.03, 0.2, 0.18], audio: speech))
    }

    func testConfidentDecodePassed() {
        XCTAssertFalse(DecodeCheck.failed(confidences: [0.9, 0.62, 0.97], audio: speech))
    }
}
