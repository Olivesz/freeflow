import AVFoundation
import Foundation
import SwiftWhisper

/// Hidden mode: `Freeflow --selftest <16kHz-mono.wav>`.
/// Replays the wav in growing slices through the real Whisper + WhisperStreamer
/// path and prints per-tick deltas — proves the streaming port without a mic.
enum SelfTest {
    static func run(_ wavPath: String) {
        Task {
            do { try await go(wavPath) } catch { print("selftest error: \(error)") }
            exit(0)
        }
        dispatchMain()   // services the main queue so SwiftWhisper's async can resume
    }

    private static func go(_ wavPath: String) async throws {
        guard let modelURL = ModelLocator.baseEN() else { print("no model"); return }
        let frames = try readWav(URL(fileURLWithPath: wavPath))
        print("audio: \(String(format: "%.1f", Double(frames.count) / 16000))s")

        let params = WhisperParams(strategy: Dictation.samplingStrategy)   // greedy — beam SIGTRAPs
        params.language = .english
        params.token_timestamps = true
        params.max_len = 1
        params.split_on_word = true
        params.print_realtime = false
        params.print_progress = false
        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        let streamer = WhisperStreamer()

        var assembled = "", ticks = 0
        let step = Int(0.35 * 16000)
        var k = step
        while k < frames.count {
            let start = streamer.windowStartSample()
            if k > start {
                let segs = try await whisper.transcribe(audioFrames: Array(frames[start..<k]))
                let delta = streamer.process(window: segs).map(\.text).joined()
                if !delta.isEmpty {
                    ticks += 1; assembled += delta
                    print(String(format: "  t=%.2fs  +%@", Double(k) / 16000, "'\(delta)'"))
                }
            }
            k += step
        }
        let start = streamer.windowStartSample()
        let segs = try await whisper.transcribe(audioFrames: Array(frames[start...]))
        assembled += streamer.finalize(window: segs).map(\.text).joined()

        print("streamed across \(ticks) ticks; trim offset=\(String(format: "%.1f", streamer.offset))s")
        print("RESULT: '\(assembled.trimmingCharacters(in: .whitespaces))'")
    }

    /// Like `run`, but pipes the streamer's committed words through the real
    /// TextProcessor (filler/commands/vocab/auto-cap) and prints the exact text
    /// that would be typed — end-to-end proof on real Whisper audio, no mic.
    static func runProc(_ wavPath: String) {
        Task {
            do { try await goProc(wavPath) } catch { print("selftest-proc error: \(error)") }
            exit(0)
        }
        dispatchMain()
    }

    private static func goProc(_ wavPath: String) async throws {
        guard let modelURL = ModelLocator.baseEN() else { print("no model"); return }
        let frames = try readWav(URL(fileURLWithPath: wavPath))

        // Match the app: greedy by default (beam SIGTRAPs on some audio). --beam to compare.
        let strategy: WhisperSamplingStrategy =
            CommandLine.arguments.contains("--beam") ? .beamSearch : Dictation.samplingStrategy
        let params = WhisperParams(strategy: strategy)
        params.language = .english
        params.token_timestamps = true
        params.max_len = 1
        params.split_on_word = true
        params.print_realtime = false
        params.print_progress = false
        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        let streamer = WhisperStreamer()
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

        let step = Int(0.35 * 16000)
        var k = step
        while k < frames.count {
            let start = streamer.windowStartSample()
            if k > start {
                let words = try await whisper.transcribe(audioFrames: Array(frames[start..<k]))
                let committed = streamer.process(window: words)
                raw += committed.map(\.text).joined()
                all += committed
                apply(proc.feed(committed))
            }
            k += step
        }
        let start = streamer.windowStartSample()
        let words = try await whisper.transcribe(audioFrames: Array(frames[start...]))
        let tail = streamer.finalize(window: words)
        raw += tail.map(\.text).joined()
        all += tail
        apply(proc.feed(tail))
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

    private static func readWav(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat            // AVAudioFile is always float32
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }
}
