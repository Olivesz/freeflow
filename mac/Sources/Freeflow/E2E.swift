import Foundation
import FreeflowCore

/// Hidden mode: `Freeflow --e2e <manifest.json> --out <dir> [--engine e] [--silence ms]
/// [--db <dir>] [--clips a,b] [--lead s]`.
///
/// The whole app path except the microphone and the keyboard: each clip is
/// played on the wall clock, after `--lead` seconds (default 0.5) of room
/// noise and followed by more of it, through the real `Dictation` — its tick
/// loop, endpointer, text processor and session trace — exactly as a hotkey
/// press would run it. Nothing is typed anywhere; the edits are read from the
/// trace. Per clip it writes what was typed, its WER, how long the first word
/// took, how long auto-stop took after the speech ended, and whether it cut
/// the speech off. With `--db`, every dictation also goes into a session log
/// there, the same format the app writes, so the analysis in bench/voice runs
/// on it unchanged.
enum E2E {
    struct Row {
        let id: String, seconds: Double
        let alignment: Scoring.Alignment
        let firstWord: Double?        // s from speech onset to the first insert
        let stopAfter: Double?        // s from the end of speech to the stop (auto only)
        let stop: String              // auto | timeout
        let cut: Bool                 // stopped before the speech ended
        let typed: String
    }

    static func run() -> Never {
        SelfTest.spawn {
            let a = CommandLine.arguments
            func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
            guard let manifest = arg("--e2e"), let out = arg("--out") else {
                print("usage: Freeflow --e2e <manifest.json> --out <dir> [--engine e] [--silence ms] [--db dir] [--clips a,b] [--lead s]")
                exit(2)
            }
            try await go(manifest: URL(fileURLWithPath: manifest), out: URL(fileURLWithPath: out),
                         silence: arg("--silence").flatMap(Int.init), db: arg("--db"),
                         only: arg("--clips").map { Set($0.split(separator: ",").map(String.init)) },
                         lead: arg("--lead").flatMap(Double.init) ?? 0.5)
        }
    }

    private static func go(manifest: URL, out: URL, silence: Int?, db: String?, only: Set<String>?,
                           lead: Double) async throws {
        let m = try JSONDecoder().decode(Bench.Manifest.self, from: Data(contentsOf: manifest))
        let clips = m.clips.filter { only?.contains($0.id) ?? true }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let source = FileAudioSource()
        let dictation = Dictation(audio: source, engine: SelfTest.engineArg())
        dictation.trigger = "e2e"
        dictation.appOverride = "e2e"
        dictation.silenceOverrideMs = silence
        let log = db.map { SessionLog(dir: URL(fileURLWithPath: $0)) }
        while !dictation.isReady { try await Task.sleep(nanoseconds: 50_000_000) }
        print("engine: \(dictation.engineName)")

        var rows: [Row] = []
        for clip in clips {
            let x = try SelfTest.readWav(manifest.deletingLastPathComponent().appendingPathComponent(clip.path))
            source.load(x, lead: lead)
            let (onset, end) = speechSpan(x)
            let trace: SessionTrace = try await withCheckedThrowingContinuation { cont in
                var done = false
                dictation.onFinished = { t in if !done { done = true; cont.resume(returning: t) } }
                DispatchQueue.main.async { dictation.start() }
                // Timeout: the clip, plus the longest hold auto-stop can take, plus slack.
                let limit = Double(x.count) / 16000 + lead + 3 * Double(silence ?? Settings.shared.silenceMs) / 1000 + 5
                DispatchQueue.main.asyncAfter(deadline: .now() + limit) { if !done { dictation.stop() } }
            }
            log?.record(trace)
            let speechStart = lead + onset, speechEnd = lead + end
            let firstInsert = trace.ops.first { if case .insert = $0.op { return true }; return false }?.t
            let stopT = trace.ticks.last { $0.stop }?.t
            let row = Row(id: clip.id, seconds: Double(x.count) / 16000,
                          alignment: Scoring.align(reference: Scoring.normalize(clip.text),
                                                   hypothesis: Scoring.normalize(trace.typed)),
                          firstWord: firstInsert.map { $0 - speechStart },
                          stopAfter: stopT.map { $0 - speechEnd },
                          stop: trace.stopReason == .auto ? "auto" : "timeout",
                          cut: stopT.map { $0 < speechEnd } ?? false,
                          typed: trace.typed)
            rows.append(row)
            print(String(format: "%@  WER %.3f  first word %@  stop %@ %@%@", clip.id, row.alignment.wer,
                         row.firstWord.map { String(format: "%.2fs", $0) } ?? "-",
                         row.stop, row.stopAfter.map { String(format: "%+.2fs", $0) } ?? "",
                         row.cut ? "  CUT" : ""))
        }
        log?.drain()
        try csv(rows).write(to: out.appendingPathComponent("e2e.csv"), atomically: true, encoding: .utf8)
        let total = rows.reduce(Scoring.Alignment(reference: 0, substitutions: 0, deletions: 0, insertions: 0)) {
            Scoring.Alignment(reference: $0.reference + $1.alignment.reference,
                              substitutions: $0.substitutions + $1.alignment.substitutions,
                              deletions: $0.deletions + $1.alignment.deletions,
                              insertions: $0.insertions + $1.alignment.insertions)
        }
        let fw = rows.compactMap(\.firstWord), st = rows.compactMap(\.stopAfter)
        print(String(format: "ALL  WER %.3f  first word p50 %.2fs  stop p50 %.2fs  cut %d/%d  timeouts %d",
                     total.wer, Scoring.percentile(fw, 50) ?? .nan, Scoring.percentile(st, 50) ?? .nan,
                     rows.filter(\.cut).count, rows.count, rows.filter { $0.stop == "timeout" }.count))
    }

    /// Where the speech in a clip starts and ends: the first and last 50 ms
    /// frame clearly above the clip's own quietest frames.
    static func speechSpan(_ x: [Float]) -> (Double, Double) {
        let frame = 800
        let rms = stride(from: 0, to: max(0, x.count - frame + 1), by: frame).map { Audio.rms(x[$0..<($0 + frame)]) }
        guard let floor = rms.sorted().dropFirst(rms.count / 10).first else { return (0, Double(x.count) / 16000) }
        let thr = max(0.01, floor * 4)
        let first = rms.firstIndex { $0 > thr } ?? 0, last = rms.lastIndex { $0 > thr } ?? (rms.count - 1)
        return (Double(first * frame) / 16000, Double((last + 1) * frame) / 16000)
    }

    private static func csv(_ rows: [Row]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func f(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "" }
        var lines = ["clip,seconds,ref_words,errors,wer,first_word_s,stop_after_s,stop,cut,typed"]
        for r in rows {
            lines.append([r.id, String(format: "%.2f", r.seconds), String(r.alignment.reference),
                          String(r.alignment.errors), String(format: "%.4f", r.alignment.wer),
                          f(r.firstWord), f(r.stopAfter), r.stop, r.cut ? "1" : "0", q(r.typed)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A clip played back on the wall clock as if it were the mic: `lead` seconds
/// of room noise, the clip, then room noise for as long as the dictation runs.
/// The same steady noise (fixed seed, RMS 0.001) sits under all of it, as in
/// --pause-bench, so the endpointer hears a room rather than digital silence.
final class FileAudioSource: AudioSource {
    private var buffer: [Float] = []
    private var t0 = Date()
    private let lock = NSLock()
    var deviceName: String { "e2e playback" }

    func load(_ x: [Float], lead: Double) {
        let pre = [Float](repeating: 0, count: Int(lead * 16000))
        var y = pre + x + [Float](repeating: 0, count: 60 * 16000)
        var rng: UInt64 = 0x9E3779B97F4A7C15
        for i in y.indices {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            y[i] += (Float(rng >> 40) / Float(1 << 24) * 2 - 1) * 0.001 * 1.732
        }
        lock.lock(); buffer = y; lock.unlock()
    }

    func start() throws { lock.lock(); t0 = Date(); lock.unlock() }
    func stop() {}

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let n = min(buffer.count, Int(Date().timeIntervalSince(t0) * 16000))
        return Array(buffer[..<n])
    }

    func recentRMS(ms: Int) -> Float { Audio.rms(snapshot().suffix(16 * ms)) }
    func recentQuietestRMS(ms: Int) -> Float { Audio.quietestFrameRMS(snapshot().suffix(16 * ms)) }
    func rms(fromSec: Double, toSec: Double) -> Float {
        let s = snapshot(), a = max(0, Int(fromSec * 16000)), b = min(s.count, Int(toSec * 16000))
        return b > a ? Audio.rms(s[a..<b]) : 0
    }
}
