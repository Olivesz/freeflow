import FreeflowCore
import XCTest

/// Runs the shared fixtures in tests/fixtures (repo root) against the app's
/// streamer. pytest runs the same files against the Python reference
/// (tests/test_fixtures.py), so the two implementations cannot drift apart.
final class StreamFixtureTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures")

    private struct Fixture: Decodable {
        struct Config: Decodable { let trim_after_s: Double; let context_s: Double }
        struct Pass: Decodable {
            let words: [[Token]]
            let commit: [String]
            let pending: [String]?
            let offset: Double
            let final: Bool?
            let duration: Double?
        }
        let config: Config?
        let passes: [Pass]
    }

    /// A word triple is [text, start, end]: mixed types, so decode each cell.
    private enum Token: Decodable {
        case text(String), time(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .time(try c.decode(Double.self)) }
        }
        var text: String { if case .text(let s) = self { return s }; return "" }
        var time: Double { if case .time(let t) = self { return t }; return 0 }
    }

    private func run(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.fixtures.appendingPathComponent("streams/\(name).json")
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let config = fx.config.map { WhisperStreamer.Config(trimAfter: $0.trim_after_s, context: $0.context_s) }
            ?? .shipped
        let streamer = WhisperStreamer(config: config)
        for (n, p) in fx.passes.enumerated() {
            let words = p.words.map { Word(text: $0[0].text, start: $0[1].time, end: $0[2].time) }
            let out = p.final == true ? streamer.finalize(window: words, duration: p.duration)
                                      : streamer.process(window: words, duration: p.duration)
            XCTAssertEqual(out.map(\.text), p.commit, "\(name) pass \(n): commit", file: file, line: line)
            if let pending = p.pending {
                XCTAssertEqual(streamer.pendingWords.map(\.text), pending, "\(name) pass \(n): pending",
                               file: file, line: line)
            }
            XCTAssertEqual(streamer.offset, p.offset, accuracy: 1e-9, "\(name) pass \(n): offset",
                           file: file, line: line)
        }
    }

    /// Every fixture on disk has a test below, so a new fixture can't be skipped.
    func testEveryFixtureIsCovered() throws {
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.appendingPathComponent("streams").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        XCTAssertEqual(onDisk, Self.covered.sorted())
    }

    static let covered = [
        "first_pass_commits_nothing", "second_agreeing_pass_commits", "disagreeing_pass_commits_nothing",
        "committed_words_are_not_reemitted", "boundary_repeat_is_deduped_by_text", "trimming_bounds_the_window",
        "final_pass_commits_the_tail_once", "nonspeech_tokens_never_commit",
        "retimed_committed_word_does_not_drop_the_next", "runaway_timestamp_is_clamped",
        "repeated_word_is_typed_twice",
    ]

    func testFirstPassCommitsNothing() throws { try run("first_pass_commits_nothing") }
    func testSecondAgreeingPassCommits() throws { try run("second_agreeing_pass_commits") }
    func testDisagreeingPassCommitsNothing() throws { try run("disagreeing_pass_commits_nothing") }
    func testCommittedWordsAreNotReemitted() throws { try run("committed_words_are_not_reemitted") }
    func testBoundaryRepeatIsDedupedByText() throws { try run("boundary_repeat_is_deduped_by_text") }
    func testTrimmingBoundsTheWindow() throws { try run("trimming_bounds_the_window") }
    func testFinalPassCommitsTheTailOnce() throws { try run("final_pass_commits_the_tail_once") }
    func testNonspeechTokensNeverCommit() throws { try run("nonspeech_tokens_never_commit") }
    func testRetimedCommittedWordDoesNotDropTheNext() throws { try run("retimed_committed_word_does_not_drop_the_next") }
    func testRunawayTimestampIsClamped() throws { try run("runaway_timestamp_is_clamped") }
    func testRepeatedWordIsTypedTwice() throws { try run("repeated_word_is_typed_twice") }

    /// The shipped window is pinned in tests/fixtures/window.json; the Python
    /// reference's default is checked against the same file.
    func testShippedWindowMatchesTheSharedFixture() throws {
        struct Window: Decodable { let trim_after_s: Double; let context_s: Double }
        let w = try JSONDecoder().decode(Window.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("window.json")))
        XCTAssertEqual(WhisperStreamer.Config.shipped, WhisperStreamer.Config(trimAfter: w.trim_after_s, context: w.context_s))
    }

    func testNonspeechFilter() throws {
        struct Lists: Decodable { let nonspeech: [String]; let speech: [String] }
        let l = try JSONDecoder().decode(Lists.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("nonspeech.json")))
        for s in l.nonspeech { XCTAssertTrue(isNonSpeech(s), "should be dropped: \(s)") }
        for s in l.speech { XCTAssertFalse(isNonSpeech(s), "should pass: \(s)") }
    }
}
