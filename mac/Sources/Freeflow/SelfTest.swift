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

        let params = WhisperParams(strategy: .beamSearch)
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
                let delta = streamer.process(window: segs)
                if !delta.isEmpty {
                    ticks += 1; assembled += delta
                    print(String(format: "  t=%.2fs  +%@", Double(k) / 16000, "'\(delta)'"))
                }
            }
            k += step
        }
        let start = streamer.windowStartSample()
        let segs = try await whisper.transcribe(audioFrames: Array(frames[start...]))
        assembled += streamer.finalize(window: segs)

        print("streamed across \(ticks) ticks; trim offset=\(String(format: "%.1f", streamer.offset))s")
        print("RESULT: '\(assembled.trimmingCharacters(in: .whitespaces))'")
    }

    private static func readWav(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat            // AVAudioFile is always float32
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }
}
