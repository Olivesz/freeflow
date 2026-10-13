import AVFoundation
import Foundation
import SwiftWhisper

/// Locates the whisper model: bundled in the app first, else the copy that the
/// Python prototype already downloaded (handy during development).
enum ModelLocator {
    static func baseEN() -> URL? {
        if let u = Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin") { return u }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let p = home.appendingPathComponent(
            "Library/Application Support/pywhispercpp/models/ggml-base.en.bin")
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
}

/// Streaming dictation on whisper.cpp. Every ~350 ms it transcribes the growing
/// (trimmed) audio window and injects only the newly-stable words — append-only,
/// so nothing already typed is ever revised or deleted. Auto-stops on silence.
final class Dictation {
    private let audio = AudioCapture()
    private let streamer = WhisperStreamer()
    private let processor = TextProcessor()
    private var whisper: Whisper?

    private var running = false
    private(set) var isRunning = false

    /// Edits to apply to the focused field (insert text / bounded backspace).
    var onOps: (([TextOp]) -> Void)?
    var onState: ((Bool) -> Void)?
    var onLevel: ((Float) -> Void)?          // live mic loudness 0…1 (for UI reactivity)
    /// Final transcript text when an utterance ends (for history). "" is skipped.
    var onFinished: ((String) -> Void)?

    private let tickMs = 350
    private var silenceMs: Int { Settings.shared.silenceMs }   // live-tunable in settings
    private let graceMs = 400
    private let silenceFloor: Float = 0.006

    var isReady: Bool { whisper != nil }

    // Load the model OFF the main thread: on a fresh build the Core ML encoder
    // compiles for the Neural Engine ("first run may take a while"), which would
    // otherwise block the UI and leave the window blank for seconds at launch.
    init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.loadModel() }
    }

    /// Decoding strategy. MUST stay greedy: beam search SIGTRAPs whisper.cpp
    /// (exit 133) on some audio, crashing the app mid-dictation and losing the
    /// user's words. Its quality edge is also gone with the small rolling window.
    /// A regression test (`--test-text`) fails if this is ever set to beam.
    static let samplingStrategy: WhisperSamplingStrategy = .greedy
    static var isGreedyDecoding: Bool {
        switch samplingStrategy { case .greedy: return true; default: return false }
    }

    private func loadModel() {
        guard let url = ModelLocator.baseEN() else { return }
        let params = WhisperParams(strategy: Dictation.samplingStrategy)
        params.language = .english
        params.token_timestamps = true
        params.max_len = 1              // one word per segment → word-level timing
        params.split_on_word = true
        params.single_segment = false
        params.print_realtime = false
        params.print_progress = false
        let w = Whisper(fromFileURL: url, withParams: params)
        DispatchQueue.main.async { [weak self] in self?.whisper = w }
    }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard whisper != nil, !isRunning else { return }
        streamer.reset()
        processor.config = Settings.shared.textProcessorConfig()   // pick up live toggle/vocab changes
        processor.reset()
        do { try audio.start() } catch { return }
        running = true; isRunning = true
        onState?(true)
        Task.detached(priority: .userInitiated) { [weak self] in await self?.loop() }
        Task.detached(priority: .utility) { [weak self] in await self?.levelLoop() }
    }

    /// Publishes mic loudness ~18×/sec so the UI can react smoothly to the voice.
    private func levelLoop() async {
        while running {
            let lvl = min(1.0, audio.recentRMS(ms: 120) / 0.06)
            onLevel?(Float(lvl))
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
        onLevel?(0)
    }

    /// Signals the loop to finish; the loop itself does the final flush + teardown
    /// so a hotkey-stop and a silence-stop can't race into a double teardown.
    func stop() {
        guard isRunning else { return }
        running = false
    }

    private func loop() async {
        guard let whisper else { return }
        var silence = 0, elapsed = 0
        let recordStart = Date()
        var maxTranscribeMs = 0, ticks = 0

        while running {
            let started = Date()
            let full = audio.snapshot()
            let startS = streamer.windowStartSample()
            if full.count - startS >= 8000 {                // ≥ 0.5 s of window
                let window = trimTrailingSilence(Array(full[startS...]))
                if rms(window) >= silenceFloor {            // skip dead-silent windows
                    let t0 = Date()
                    let segs = try? await whisper.transcribe(audioFrames: window)
                    maxTranscribeMs = max(maxTranscribeMs, Int(Date().timeIntervalSince(t0) * 1000))
                    ticks += 1
                    if let segs {
                        let ops = processor.feed(streamer.process(window: segs))
                        if !ops.isEmpty { emit(ops) }
                    }
                }
                if elapsed >= graceMs {                     // VAD auto-stop
                    silence = audio.recentRMS(ms: tickMs) < silenceFloor ? silence + tickMs : 0
                }
                if silence >= silenceMs { running = false }
            }
            elapsed += tickMs
            let spent = Int(Date().timeIntervalSince(started) * 1000)
            if spent < tickMs {
                try? await Task.sleep(nanoseconds: UInt64(tickMs - spent) * 1_000_000)
            }
        }

        // final flush — trim the trailing silence (auto-stop leaves ~1.5s of it,
        // which is exactly what Whisper hallucinates "thank you" etc. onto).
        let full = audio.snapshot()
        let startS = streamer.windowStartSample()
        let tail = trimTrailingSilence(Array(full[max(0, startS)...]))
        var finalOps: [TextOp] = []
        if tail.count > 800, let segs = try? await whisper.transcribe(audioFrames: tail) {
            finalOps += processor.feed(streamer.finalize(window: segs))
        }
        finalOps += processor.flush()          // emit any word held for lookahead
        if !finalOps.isEmpty { emit(finalOps) }

        let finalText = processor.emitted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty { let t = finalText; await MainActor.run { self.onFinished?(t) } }

        Diag.utterance(fullSamples: full.count, wall: Date().timeIntervalSince(recordStart),
                       maxTranscribeMs: maxTranscribeMs, ticks: ticks,
                       words: streamer.committedWords) { self.audio.rms(fromSec: $0, toSec: $1) }
        audio.stop()
        isRunning = false
        await MainActor.run { self.onState?(false) }
    }

    private func emit(_ ops: [TextOp]) {
        DispatchQueue.main.async { self.onOps?(ops) }
    }

    private func rms(_ frames: [Float]) -> Float {
        guard !frames.isEmpty else { return 0 }
        let sum = frames.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(frames.count)).squareRoot()
    }

    /// Cut trailing quiet off the window so Whisper never transcribes silence
    /// (which it "fills in" with hallucinated phrases like "thank you"). Scans
    /// back in 50ms frames to the last voiced one and keeps ~0.2s of padding.
    private func trimTrailingSilence(_ frames: [Float]) -> [Float] {
        let frame = 800                                   // 50 ms @ 16 kHz
        let floor: Float = 0.010
        var i = frames.count - frame
        while i > 0 {
            let slice = frames[i..<min(i + frame, frames.count)]
            let s = slice.reduce(Float(0)) { $0 + $1 * $1 }
            if (s / Float(slice.count)).squareRoot() > floor {
                let end = min(frames.count, i + frame + 3200)   // keep +0.2 s
                return end < frames.count ? Array(frames[0..<end]) : frames
            }
            i -= frame
        }
        return frames   // no clear voiced tail found — leave it, other guards apply
    }
}
