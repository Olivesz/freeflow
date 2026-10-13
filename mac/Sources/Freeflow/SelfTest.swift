import AVFoundation
import Foundation
import FreeflowCore
import SwiftWhisper

/// Offline replays of a 16 kHz mono WAV through the real whisper.cpp model and
/// the same StreamingSession the live app uses, at the app's 350 ms tick.
///
///   Freeflow --selftest <wav>        per-tick deltas and the streamed result
///   Freeflow --selftest-proc <wav>   the same, piped through TextProcessor
///   (either takes --beam, and --trim <after>/<context> to override the window)
enum SelfTest {
    static let tickSamples = Int(0.35 * 16000)

    static func run(_ wavPath: String) { spawn { try await go(wavPath) } }
    static func runProc(_ wavPath: String) { spawn { try await goProc(wavPath) } }

    /// Runs `body` and exits; dispatchMain services the main queue so
    /// SwiftWhisper's async calls can resume.
    static func spawn(_ body: @escaping () async throws -> Void) -> Never {
        Task {
            do { try await body() } catch { print("error: \(error)") }
            exit(0)
        }
        dispatchMain()
    }

    // MARK: - shared plumbing

    static func decodingArg() -> Decoding {
        CommandLine.arguments.contains("--beam") ? .beam : .shipped
    }

    /// `--trim 3.0/1.5` overrides the shipped window; "none" disables trimming.
    static func configArg() -> WhisperStreamer.Config {
        guard let i = CommandLine.arguments.firstIndex(of: "--trim"),
              i + 1 < CommandLine.arguments.count else { return .shipped }
        return parseConfig(CommandLine.arguments[i + 1]) ?? .shipped
    }

    static func parseConfig(_ s: String) -> WhisperStreamer.Config? {
        if s == "none" { return WhisperStreamer.Config(trimAfter: .infinity, context: 0) }
        let parts = s.split(separator: "/").compactMap { Double($0) }
        return parts.count == 2 ? WhisperStreamer.Config(trimAfter: parts[0], context: parts[1]) : nil
    }

    static func loadWhisper(_ decoding: Decoding) throws -> Whisper {
        guard let url = ModelLocator.baseEN() else { throw SelfTestError.noModel }
        return Whisper(fromFileURL: url, withParams: WhisperSetup.params(decoding))
    }

    /// Feeds the clip to `session` as it would arrive live: one tick per 350 ms
    /// of audio, then the stop pass. Calls `onCommit` with each tick's words.
    static func replay(_ frames: [Float], session: StreamingSession, decoder: WordDecoder,
                       onCommit: (Double, [Word]) -> Void = { _, _ in }) async throws {
        var k = tickSamples
        while k < frames.count {
            let words = try await session.tick(audio: Array(frames[..<k]), decoder: decoder)
            if !words.isEmpty { onCommit(Double(k) / 16000, words) }
            k += tickSamples
        }
        let tail = try await session.finish(audio: frames, decoder: decoder)
        if !tail.isEmpty { onCommit(Double(frames.count) / 16000, tail) }
    }

    static func readWav(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat            // AVAudioFile is always float32
        guard fmt.sampleRate == 16000, fmt.channelCount == 1 else { throw SelfTestError.format(url.path) }
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    enum SelfTestError: Error { case noModel, format(String) }

    // MARK: - modes

    private static func go(_ wavPath: String) async throws {
        let frames = try readWav(URL(fileURLWithPath: wavPath))
        print("audio: \(String(format: "%.1f", Double(frames.count) / 16000))s")
        let whisper = try loadWhisper(decodingArg())
        let session = StreamingSession(config: configArg())
        var assembled = "", ticks = 0
        try await replay(frames, session: session, decoder: whisper) { t, words in
            let delta = words.map(\.text).joined()
            ticks += 1; assembled += delta
            print(String(format: "  t=%.2fs  +%@", t, "'\(delta)'"))
        }
        print("streamed across \(ticks) ticks; trim offset=\(String(format: "%.1f", session.streamer.offset))s")
        print("RESULT: '\(assembled.trimmingCharacters(in: .whitespaces))'")
    }

    /// Like `go`, but pipes the committed words through the real TextProcessor
    /// (filler/commands/vocab/auto-cap) and prints the exact text that would be typed.
    private static func goProc(_ wavPath: String) async throws {
        let frames = try readWav(URL(fileURLWithPath: wavPath))
        let whisper = try loadWhisper(decodingArg())
        let session = StreamingSession(config: configArg())
        var cfg = TextProcessor.Config()
        cfg.vocab = ["neuro": "neural", "gpt": "GPT",
                     "gthub": "GitHub", "open eye": "OpenAI", "s code": "VS Code"]
        let proc = TextProcessor(config: cfg)

        var field = "", raw = "", all: [Word] = []
        func apply(_ ops: [TextOp]) {
            for op in ops {
                switch op {
                case .insert(let s): field += s
                case .delete(let n): field = String(field.dropLast(n))
                }
            }
        }
        try await replay(frames, session: session, decoder: whisper) { _, words in
            raw += words.map(\.text).joined()
            all += words
            apply(proc.feed(words))
        }
        apply(proc.flush())

        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "⏎") }
        // Gap before each word — shows where the real pauses are (for command scoping).
        var prevEnd = 0.0
        for w in all {
            let gap = w.start - prevEnd
            print(String(format: "  %+.2fs gap  %@", gap, w.text.trimmingCharacters(in: .whitespaces))
                  + (gap >= 0.35 ? "   ⟵ pause" : ""))
            prevEnd = w.end
        }
        print("RAW:   >>>\(esc(raw))<<<")     // streamer only — isolates Whisper/streamer from the processor
        print("TYPED: >>>\(esc(field))<<<")   // full pipeline — what actually lands in the field
    }
}
