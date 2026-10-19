import FreeflowCore
import XCTest

/// The per-tick rules around the decoder, with a scripted decoder in place of
/// whisper.cpp.
final class SessionTests: XCTestCase {
    /// Returns the next scripted pass on each call and records the window sizes.
    final class Scripted: WordDecoder {
        var script: [[Word]]
        var received: [Int] = []
        init(_ script: [[Word]]) { self.script = script }
        func words(_ frames: [Float]) async throws -> [Word] {
            received.append(frames.count)
            return script.isEmpty ? [] : script.removeFirst()
        }
    }

    private func speech(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(seconds * 16000))
    }

    func testSilenceAndTinyWindowsNeverReachTheDecoder() async throws {
        let decoder = Scripted([])
        let session = StreamingSession()
        let silent = try await session.tick(audio: [Float](repeating: 0, count: 3 * 16000), decoder: decoder)
        let tiny = try await session.tick(audio: speech(0.25), decoder: decoder)
        XCTAssertEqual(silent, [])
        XCTAssertEqual(tiny, [])
        XCTAssertEqual(decoder.received, [])
    }

    func testTwoAgreeingTicksCommitAndArePassLogged() async throws {
        let hello = [Word(text: "hello", start: 0, end: 0.5)]
        let decoder = Scripted([hello, hello])
        let session = StreamingSession()
        let a = try await session.tick(audio: speech(1.0), decoder: decoder)
        let b = try await session.tick(audio: speech(1.35), decoder: decoder)
        XCTAssertEqual(a, [])
        XCTAssertEqual(b.map(\.text), [" hello"])
        XCTAssertEqual(session.passes.map(\.audioEnd), [1.0, 1.35])
        XCTAssertEqual(session.passes.last?.committed.map(\.text), [" hello"])
    }

    func testEndpointerStopsAfterSilenceOnlyPastTheGrace() {
        var e = SilenceEndpointer(tickMs: 350, graceMs: 400)
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))   // t=0: inside the grace period
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))   // t=350: still inside
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))   // t=700: 350 ms of silence
        XCTAssertTrue(e.tick(rms: 0, silenceMs: 700))    // t=1050: 700 ms → stop
    }

    func testEndpointerResetsOnSpeech() {
        var e = SilenceEndpointer(tickMs: 350, graceMs: 0)
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))
        XCTAssertFalse(e.tick(rms: 0.05, silenceMs: 700))   // speech resets the count
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))
        XCTAssertTrue(e.tick(rms: 0, silenceMs: 700))
    }

    /// A quiet speaker in a quiet room: speech at 0.005 RMS, under the old fixed
    /// 0.006 floor, which read it as silence and stopped mid-sentence.
    func testQuietSpeechInAQuietRoomIsNotSilence() {
        var e = SilenceEndpointer(tickMs: 350, graceMs: 0)
        for _ in 0..<3 { _ = e.tick(rms: 0.001, silenceMs: 700) }   // room noise sets the floor
        for _ in 0..<10 { XCTAssertFalse(e.tick(rms: 0.005, silenceMs: 700)) }
    }

    /// Never stricter than the shipped fixed floor: anything at or above it is
    /// speech no matter what the room taught the adaptive floor.
    func testNeverStricterThanTheFixedFloor() {
        var e = SilenceEndpointer(tickMs: 350, graceMs: 0)
        for _ in 0..<12 { _ = e.isSpeech(0.05) }              // a loud floor window
        XCTAssertTrue(e.isSpeech(SilenceEndpointer.legacyFloor))
    }

    /// Quiet speech from the very first tick: the gaps between syllables give
    /// the room reference, so it isn't read as silence. Then the room ends it.
    func testQuietSpeechFromTheFirstTickThenQuietRoomEnds() {
        var e = SilenceEndpointer(tickMs: 350, graceMs: 0)
        for _ in 0..<6 { XCTAssertFalse(e.tick(rms: 0.005, quietest: 0.0008, silenceMs: 700)) }
        XCTAssertFalse(e.tick(rms: 0.0008, silenceMs: 700))
        XCTAssertTrue(e.tick(rms: 0.0008, silenceMs: 700))
    }

    func testQuietestFrameHearsTheGapBetweenSyllables() {
        let word = [Float](repeating: 0.02, count: 2400), gap = [Float](repeating: 0.001, count: 800)
        let tick = word + gap + word                            // 350 ms: word, 50 ms gap, word
        XCTAssertEqual(Audio.quietestFrameRMS(tick[...]), 0.001, accuracy: 1e-6)
    }

    /// "…the second option is better. Because" + a thinking pause: the same silence
    /// that ends a finished sentence must not end an open one.
    func testOpenSentenceWaitsLonger() {
        var open = SilenceEndpointer(tickMs: 350, graceMs: 0)
        var done = SilenceEndpointer(tickMs: 350, graceMs: 0)
        var openStop = 0, doneStop = 0
        for i in 1...12 {
            if openStop == 0, open.tick(rms: 0, silenceMs: 700, sentenceOpen: true) { openStop = i }
            if doneStop == 0, done.tick(rms: 0, silenceMs: 700, sentenceOpen: false) { doneStop = i }
        }
        XCTAssertEqual(doneStop, 2)                                  // 700 ms
        XCTAssertEqual(openStop, 6)                                  // 2,100 ms = 3x
    }

    /// Words a sentence can't end on, as Whisper might decode them once a pause
    /// starts (it adds a period to the window's last word).
    func testContinuationWordsOverrideWhispersPeriod() {
        for t in ["Because.", " when.", "Than", " inter-", " the.", " and,"] {
            XCTAssertTrue(Word(text: t, start: 0, end: 1).continuesSentence, t)
        }
        for t in [" wizard.", " better.", " today", " it."] {
            XCTAssertFalse(Word(text: t, start: 0, end: 1).continuesSentence, t)
        }
    }

    func testSentenceOpenIgnoresTrailingSymbolsAndSeesTheWord() async throws {
        let decoder = Scripted([[Word(text: " Because.", start: 0, end: 0.5), Word(text: " ♪", start: 0.6, end: 0.8)]])
        let session = StreamingSession()
        _ = try await session.tick(audio: speech(1.0), decoder: decoder)
        XCTAssertTrue(session.sentenceOpen)
    }

    func testSentenceOpenFollowsTheLatestPass() async throws {
        let decoder = Scripted([
            [Word(text: "is", start: 0, end: 0.4), Word(text: " better.", start: 0.4, end: 0.8)],
            [Word(text: " better.", start: 0.4, end: 0.8), Word(text: " Because", start: 0.9, end: 1.3)],
        ])
        let session = StreamingSession()
        XCTAssertFalse(session.sentenceOpen)                         // nothing heard yet
        _ = try await session.tick(audio: speech(1.0), decoder: decoder)
        XCTAssertFalse(session.sentenceOpen)                         // "…better."
        _ = try await session.tick(audio: speech(1.4), decoder: decoder)
        XCTAssertTrue(session.sentenceOpen)                          // "…Because"
    }

    /// Parakeet leaves the last word bare when the window's silence is cut:
    /// a bare word is a finished thought, a trailing comma is not.
    func testBareLastWordIsClosedTrailingCommaIsOpen() async throws {
        let decoder = Scripted([
            [Word(text: " inward", start: 0, end: 0.4), Word(text: " joy", start: 0.4, end: 0.8)],
            [Word(text: " little", start: 0.4, end: 0.8), Word(text: " fir", start: 0.8, end: 1.0),
             Word(text: " tree,", start: 1.0, end: 1.3)],
        ])
        let session = StreamingSession()
        _ = try await session.tick(audio: speech(1.0), decoder: decoder)
        XCTAssertFalse(session.sentenceOpen)                         // "…inward joy"
        _ = try await session.tick(audio: speech(1.4), decoder: decoder)
        XCTAssertTrue(session.sentenceOpen)                          // "…fir tree,"
    }

    func testTrailingSilenceIsCutWithPadding() {
        let audio = speech(1.0) + [Float](repeating: 0, count: 16000)
        let cut = Audio.trimTrailingSilence(audio)
        XCTAssertEqual(cut.count, 16000 + 3200)   // the voiced second plus 0.2 s
    }
}
