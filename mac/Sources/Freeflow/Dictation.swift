import AppKit
import AVFoundation
import Foundation
import FreeflowCore
import SwiftWhisper

/// Locates the whisper model: $FREEFLOW_MODEL_DIR (set by bench/run.sh), then
/// the app bundle, else the copy the Python prototype already downloaded.
/// whisper.cpp picks up the Core ML encoder from the same directory.
enum ModelLocator {
    static let name = "whisper.cpp ggml-base.en"

    static func baseEN() -> URL? {
        if let dir = ProcessInfo.processInfo.environment["FREEFLOW_MODEL_DIR"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent("ggml-base.en.bin")
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
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
    private let audio: AudioSource
    /// Set by the --e2e harness: run this engine whatever Settings say, and
    /// never stand Whisper in for it.
    private let pinnedEngine: Engine?
    private var session = StreamingSession()
    private var config: WhisperStreamer.Config = .shipped
    private var streamer: WhisperStreamer { session.streamer }
    private let processor = TextProcessor()
    private var decoder: WordDecoder?
    /// What actually loaded (the preferred engine, or Whisper as the fallback).
    private(set) var engineName = ""
    var onEngineLoaded: ((String) -> Void)?

    private var running = false
    private(set) var isRunning = false

    /// Edits to apply to the focused field (insert text / bounded backspace).
    var onOps: (([TextOp]) -> Void)?
    var onState: ((Bool) -> Void)?
    var onLevel: ((Float) -> Void)?          // live mic loudness 0…1 (for UI reactivity)
    /// The whole dictation when it ends: what was typed, the audio, every pass,
    /// tick and edit (history, and the opt-in session log). Called even when
    /// nothing was typed: an empty dictation is data too.
    var onFinished: ((SessionTrace) -> Void)?
    /// "toggle" or "hold" (the hotkey mode), "e2e" in the harness.
    var trigger = "toggle"
    /// Harness overrides; nil means Settings.
    var silenceOverrideMs: Int?
    var processorOverride: TextProcessor.Config?
    var appOverride: String?
    private var trace: SessionTrace?

    private let tickMs = 350
    private var silenceMs: Int { silenceOverrideMs ?? Settings.shared.silenceMs }   // live-tunable in settings
    private let graceMs = 400

    var isReady: Bool { decoder != nil }

    // Load the model OFF the main thread: on a fresh build the Core ML encoder
    // compiles for the Neural Engine ("first run may take a while"), which would
    // otherwise block the UI and leave the window blank for seconds at launch.
    init(audio: AudioSource = AudioCapture(), engine: Engine? = nil) {
        self.audio = audio; pinnedEngine = engine
        reload()
    }

    /// (Re)load the engine chosen in Settings. Parakeet when it loads; Whisper
    /// base.en (bundled, so it always can) if it doesn't — no network on first
    /// launch, a broken model cache — so dictation is never unavailable. When
    /// Parakeet isn't downloaded yet, Whisper serves while it downloads, and
    /// Parakeet takes over once ready (never in the middle of a dictation).
    private var reloadWhenStopped = false
    private typealias Loaded = (decoder: WordDecoder, name: String, config: WhisperStreamer.Config)
    private var pendingInstall: Loaded?

    func reload() {
        guard !isRunning else { reloadWhenStopped = true; return }
        decoder = nil
        let preferred = pinnedEngine ?? Settings.shared.engine, pinned = pinnedEngine != nil
        Task.detached(priority: .userInitiated) {
            if pinned {
                let loaded = preferred == .parakeet ? await Dictation.loadParakeet() : Dictation.loadWhisper()
                DispatchQueue.main.async { [weak self] in if let loaded { self?.install(loaded) } }
                return
            }
            if preferred == .parakeet, !ParakeetDecoder.isDownloaded, let w = Dictation.loadWhisper() {
                DispatchQueue.main.async { [weak self] in self?.install(w) }
            }
            let loaded = preferred == .parakeet ? (await Dictation.loadParakeet() ?? Dictation.loadWhisper())
                                                : Dictation.loadWhisper()
            DispatchQueue.main.async { [weak self] in if let loaded { self?.install(loaded) } }
        }
    }

    /// Swap the engine in, or hold it until the current dictation ends: the
    /// running loop and its session belong to the engine they started with.
    private func install(_ e: Loaded) {
        guard !isRunning else { pendingInstall = e; return }
        session = StreamingSession(config: e.config)
        config = e.config
        decoder = e.decoder; engineName = e.name
        onEngineLoaded?(e.name)
    }

    private static func loadParakeet() async -> Loaded? {
        guard let p = try? await ParakeetDecoder.load() else { return nil }
        return (p, ParakeetDecoder.name, .parakeet)
    }

    private static func loadWhisper() -> Loaded? {
        guard let url = ModelLocator.baseEN() else { return nil }
        return (Whisper(fromFileURL: url, withParams: WhisperSetup.params(.shipped)), ModelLocator.name, .shipped)
    }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard decoder != nil, !isRunning else { return }
        session.reset()
        processor.config = Settings.shared.textProcessorConfig()   // pick up live toggle/vocab changes
        processor.reset()
        let t = SessionTrace(engine: engineName, config: config, silenceMs: silenceMs, tickMs: tickMs,
                             device: audio.deviceName)
        t.trigger = trigger
        t.app = appOverride ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        trace = t
        do { try audio.start() } catch { trace = nil; return }
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
        guard let decoder, let trace else { return }
        var endpointer = SilenceEndpointer(tickMs: tickMs, graceMs: graceMs)
        let recordStart = Date()
        var maxTranscribeMs = 0, ticks = 0

        while running {
            let started = Date()
            let full = audio.snapshot()
            let startS = streamer.windowStartSample()
            var level: Float?                               // nil = window too short to judge
            var quietest: Float?
            if full.count - startS >= StreamingSession.minWindowSamples {
                let before = session.passes.count
                if let words = try? await session.tick(audio: full, decoder: decoder) {
                    let ops = processor.feed(words)
                    if !ops.isEmpty { emit(ops) }
                }
                if session.passes.count > before, let p = session.passes.last {
                    maxTranscribeMs = max(maxTranscribeMs, Int(p.decodeMs)); ticks += 1
                    record(p, decoder)
                }
                level = audio.recentRMS(ms: tickMs)
                quietest = audio.recentQuietestRMS(ms: tickMs)
            }
            let open = session.sentenceOpen
            let stopNow = endpointer.tick(rms: level, quietest: quietest, silenceMs: silenceMs,
                                          sentenceOpen: open)
            trace.ticks.append(.init(t: trace.now, audioEnd: Double(full.count) / 16000,
                                     rms: level, quietest: quietest, noiseFloor: endpointer.noiseFloor,
                                     voiced: level != nil && endpointer.lastVoiced,
                                     silentMs: endpointer.silentMs, limitMs: endpointer.lastLimitMs,
                                     sentenceOpen: open, stop: stopNow))
            if stopNow {
                running = false                             // VAD auto-stop
                trace.stopReason = .auto
            }
            let spent = Int(Date().timeIntervalSince(started) * 1000)
            if spent < tickMs {
                try? await Task.sleep(nanoseconds: UInt64(tickMs - spent) * 1_000_000)
            }
        }

        // final flush — trim the trailing silence (auto-stop leaves ~1.5s of it,
        // which is exactly what Whisper hallucinates "thank you" etc. onto).
        let full = audio.snapshot()
        var finalOps: [TextOp] = []
        let before = session.passes.count
        if let words = try? await session.finish(audio: full, decoder: decoder) {
            finalOps += processor.feed(words)
        }
        if session.passes.count > before, let p = session.passes.last { record(p, decoder) }
        finalOps += processor.flush()          // emit any word held for lookahead
        if !finalOps.isEmpty { emit(finalOps) }

        trace.typed = processor.emitted
        trace.audio = full
        trace.ended = Date()
        self.trace = nil
        await MainActor.run { self.onFinished?(trace) }

        Diag.utterance(fullSamples: full.count, wall: Date().timeIntervalSince(recordStart),
                       maxTranscribeMs: maxTranscribeMs, ticks: ticks,
                       words: streamer.committedWords) { self.audio.rms(fromSec: $0, toSec: $1) }
        audio.stop()
        isRunning = false
        await MainActor.run {
            self.onState?(false)
            if let e = self.pendingInstall { self.pendingInstall = nil; self.install(e) }
            if self.reloadWhenStopped { self.reloadWhenStopped = false; self.reload() }
        }
    }

    private func emit(_ ops: [TextOp]) {
        if let trace { let t = trace.now; trace.ops += ops.map { .init(t: t, op: $0) } }
        DispatchQueue.main.async { self.onOps?(ops) }
    }

    private func record(_ p: Pass, _ decoder: WordDecoder) {
        guard let trace else { return }
        let r = decoder as? TokenReporting
        trace.passes.append(.init(t: trace.now, pass: p, tokens: r?.lastTokens ?? [], retried: r?.lastRetried ?? false))
    }
}

/// whisper.cpp parameters shared by the app, --selftest and --bench.
enum WhisperSetup {
    static func params(_ decoding: Decoding) -> WhisperParams {
        let params = WhisperParams(strategy: decoding == .beam ? .beamSearch : .greedy)
        params.language = .english
        params.token_timestamps = true
        params.max_len = 1              // one word per segment → word-level timing
        params.split_on_word = true
        params.single_segment = false
        params.print_realtime = false
        params.print_progress = false
        return params
    }
}

extension Whisper: WordDecoder {
    /// SwiftWhisper resumes the caller before it clears its busy flag, so a pass
    /// started right after the previous one returns can fail with instanceBusy.
    /// Wait out that gap instead of losing the pass.
    public func words(_ frames: [Float]) async throws -> [Word] {
        for _ in 0..<200 {
            do { return try await transcribe(audioFrames: frames).words }
            catch WhisperError.instanceBusy { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        return try await transcribe(audioFrames: frames).words
    }
}

extension Array where Element == Segment {
    /// Decoder output as core `Word`s, times in seconds relative to the window.
    var words: [Word] {
        map { Word(text: $0.text, start: Double($0.startTime) / 1000, end: Double($0.endTime) / 1000) }
    }
}
