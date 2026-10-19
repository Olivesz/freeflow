import XCTest
@testable import FreeflowCore

final class CorrectionTrailTests: XCTestCase {
    private let typed = "Send the draft to Dana by Friday."
    private var field: String { "Notes for today. " + typed }

    private func follow(_ after: String) -> CorrectionTrail.Followed? {
        let span = CorrectionTrail.locate(typed, in: field, caret: field.utf16.count)!
        return CorrectionTrail.follow(span: span, before: field, after: after)
    }

    func testLocatePrefersTheSpanEndingAtTheCaret() {
        let f = typed + " " + typed
        XCTAssertEqual(CorrectionTrail.locate(typed, in: f, caret: typed.utf16.count), 0..<typed.utf16.count)
        let last = (typed.utf16.count + 1)..<f.utf16.count
        XCTAssertEqual(CorrectionTrail.locate(typed, in: f, caret: nil), last)
        XCTAssertNil(CorrectionTrail.locate("absent", in: f, caret: nil))
    }

    func testUnchangedTextFollowsWithDistanceZero() {
        XCTAssertEqual(follow(field), .init(text: typed, distance: 0, anchored: true))
    }

    func testAWordFixIsRecovered() {
        let r = follow("Notes for today. Send the draft to Dena by Friday.")
        XCTAssertEqual(r?.text, "Send the draft to Dena by Friday.")
        XCTAssertEqual(r?.distance, 1)
    }

    /// Typing that continues after the dictation is not part of the correction.
    func testLaterTypingIsLeftOut() {
        let r = follow("Notes for today. Send the draft to Dana by Friday. Also book the room.")
        XCTAssertEqual(r?.text, typed)
        XCTAssertEqual(r?.distance, 0)
    }

    func testAnEditInTheMiddleAndMoreTypingAfter() {
        let r = follow("Notes for today. Send the final draft to Dana by Friday. Thanks")
        XCTAssertEqual(r?.text, "Send the final draft to Dana by Friday.")
        XCTAssertEqual(r?.distance, 6)
    }

    func testAClearedFieldIsLost() {
        XCTAssertNil(follow(""))
        XCTAssertNil(follow("Notes for today. "))
    }

    /// The text before the span changed too: found by searching the whole field.
    func testUnanchoredSearch() {
        let r = follow("Agenda: Send the draft to Dana by Friday!")
        XCTAssertEqual(r?.text, "Send the draft to Dana by Friday!")
        XCTAssertEqual(r?.anchored, false)
    }

    func testSpanAtTheStartOfTheField() {
        let span = CorrectionTrail.locate(typed, in: typed, caret: typed.utf16.count)!
        let r = CorrectionTrail.follow(span: span, before: typed, after: "Send the draft to Dana on Friday. ok")
        XCTAssertEqual(r?.text, "Send the draft to Dana on Friday.")
    }
}
