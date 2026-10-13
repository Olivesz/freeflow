import FreeflowCore
import XCTest

final class ScoringTests: XCTestCase {
    func testNormalizeStripsCaseAndPunctuation() {
        XCTAssertEqual(Scoring.normalize("And so, my fellow Americans!"), ["and", "so", "my", "fellow", "americans"])
        XCTAssertEqual(Scoring.normalize("DON'T well-known"), ["don't", "well", "known"])
    }

    func testAlignmentCountsEachErrorKind() {
        let ref = ["ask", "not", "what", "your", "country", "can", "do"]
        let a = Scoring.align(reference: ref, hypothesis: ["ask", "not", "country", "can", "do"])
        XCTAssertEqual(a, Scoring.Alignment(reference: 7, substitutions: 0, deletions: 2, insertions: 0))
        let b = Scoring.align(reference: ["a", "b"], hypothesis: ["a", "x", "b", "c"])
        XCTAssertEqual(b.substitutions + b.insertions, 2)
        XCTAssertEqual(b.deletions, 0)
        XCTAssertEqual(Scoring.align(reference: ref, hypothesis: ref).wer, 0)
    }

    func testJfkStreamedTranscriptScoresSixDrops() {
        let ref = Scoring.normalize("And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country.")
        let hyp = Scoring.normalize("And so my fellow Americans. ask not. country can for you? Ask what you your country.")
        let a = Scoring.align(reference: ref, hypothesis: hyp)
        XCTAssertEqual(a.deletions, 6)
        XCTAssertEqual(a.wer, 6.0 / 22.0, accuracy: 1e-12)
    }

    func testPercentileIsNearestRank() {
        XCTAssertEqual(Scoring.percentile([4, 1, 3, 2], 50), 2)
        XCTAssertEqual(Scoring.percentile([4, 1, 3, 2], 95), 4)
        XCTAssertNil(Scoring.percentile([], 50))
    }
}
