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
        var e = SilenceEndpointer(tickMs: 350, graceMs: 400, silenceFloor: 0.006)
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))   // t=0: inside the grace period
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))   // t=350: still inside
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))   // t=700: 350 ms of silence
        XCTAssertTrue(e.tick(rms: 0, silenceMs: 700))    // t=1050: 700 ms → stop
    }

    func testEndpointerResetsOnSpeech() {
        var e = SilenceEndpointer(tickMs: 350, graceMs: 0, silenceFloor: 0.006)
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))
        XCTAssertFalse(e.tick(rms: 0.05, silenceMs: 700))   // speech resets the count
        XCTAssertFalse(e.tick(rms: 0, silenceMs: 700))
        XCTAssertTrue(e.tick(rms: 0, silenceMs: 700))
    }

    func testTrailingSilenceIsCutWithPadding() {
        let audio = speech(1.0) + [Float](repeating: 0, count: 16000)
        let cut = Audio.trimTrailingSilence(audio)
        XCTAssertEqual(cut.count, 16000 + 3200)   // the voiced second plus 0.2 s
    }
}
