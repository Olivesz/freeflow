import Foundation
import FreeflowCore
import SwiftWhisper

/// Hidden mode: `Freeflow --bench <manifest.json> --out <dir> [--trim A/B|none] [--beam] [--clips a,b]`.
///
/// For every clip in the manifest it decodes the whole clip once (offline), then
/// replays it at the app's 350 ms tick through the same StreamingSession the app
/// runs, and scores both against the reference. Writes:
///   <dir>/summary.csv        one row per clip plus an ALL row (corpus WER)
///   <dir>/run.json           settings, model hash and machine
///   <dir>/logs/<clip>.jsonl  every pass: hypothesis, committed words, decode time
enum Bench {
    struct Manifest: Decodable {
        struct Clip: Decodable { let id: String; let path: String; let text: String }
        let clips: [Clip]
    }

    struct Row {
        let id: String
        let seconds: Double
        let stream: Scoring.Alignment
        let offline: Scoring.Alignment
        let lags: [Double]          // ms, per committed word
        let decodes: [Double]       // ms, per pass
        let cpuSeconds: Double      // process CPU time spent streaming this clip
        let passes: Int
        let streamText: String
        let offlineText: String
    }

    static func run() -> Never {
        SelfTest.spawn {
            let args = CommandLine.arguments
            guard let mi = args.firstIndex(of: "--bench"), mi + 1 < args.count,
                  let oi = args.firstIndex(of: "--out"), oi + 1 < args.count else {
                print("usage: Freeflow --bench <manifest.json> --out <dir> [--trim A/B|none] [--beam] [--clips a,b]")
                exit(2)
            }
            try await go(manifest: URL(fileURLWithPath: args[mi + 1]), out: URL(fileURLWithPath: args[oi + 1]))
        }
    }

    private static func go(manifest manifestURL: URL, out: URL) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        var clips = manifest.clips
        if let i = CommandLine.arguments.firstIndex(of: "--clips"), i + 1 < CommandLine.arguments.count {
            let keep = Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
            clips = clips.filter { keep.contains($0.id) }
        }
        let decoding = SelfTest.decodingArg()
        let config = SelfTest.configArg()
        let loadStart = loadAverage()
        let whisper = try SelfTest.loadWhisper(decoding)
        let logs = out.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        var rows: [Row] = []
        for clip in clips {
            let wav = manifestURL.deletingLastPathComponent().appendingPathComponent(clip.path)
            let frames = try SelfTest.readWav(wav)
            let reference = Scoring.normalize(clip.text)

            let offlineWords = try await whisper.words(frames)
            let offlineText = offlineWords.filter { !isNonSpeech($0.text) }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")

            let session = StreamingSession(config: config)
            let cpu0 = cpuSeconds()
            try await SelfTest.replay(frames, session: session, decoder: whisper)
            let cpu = cpuSeconds() - cpu0

            let committed = session.streamer.committedWords
            let streamText = committed.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            // A word is on screen once the pass that committed it has finished decoding.
            var lags: [Double] = []
            for p in session.passes {
                let typed = p.audioEnd + p.decodeMs / 1000
                lags += p.committed.map { (typed - $0.end) * 1000 }
            }
            let row = Row(id: clip.id, seconds: Double(frames.count) / 16000,
                          stream: Scoring.align(reference: reference, hypothesis: Scoring.normalize(streamText)),
                          offline: Scoring.align(reference: reference, hypothesis: Scoring.normalize(offlineText)),
                          lags: lags, decodes: session.passes.map(\.decodeMs), cpuSeconds: cpu,
                          passes: session.passes.count, streamText: streamText, offlineText: offlineText)
            rows.append(row)
            try writeLog(clip: clip, session: session, offline: offlineText, row: row,
                         to: logs.appendingPathComponent("\(clip.id).jsonl"))
            print(String(format: "%@  stream WER %.3f  offline WER %.3f  dropped %d/%d",
                         clip.id, row.stream.wer, row.offline.wer, row.stream.deletions, row.stream.reference))
        }
        try csv(rows).write(to: out.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
        try runInfo(decoding: decoding, config: config, clips: rows.count, load: (loadStart, loadAverage()))
            .write(to: out.appendingPathComponent("run.json"), atomically: true, encoding: .utf8)
        let all = total(rows)
        print(String(format: "ALL  stream WER %.3f  offline WER %.3f  dropped %d/%d  (%d clips)",
                     all.stream.wer, all.offline.wer, all.stream.deletions, all.stream.reference, rows.count))
    }

    // MARK: - output

    private static func total(_ rows: [Row]) -> (stream: Scoring.Alignment, offline: Scoring.Alignment) {
        func sum(_ k: KeyPath<Row, Scoring.Alignment>) -> Scoring.Alignment {
            Scoring.Alignment(reference: rows.map { $0[keyPath: k].reference }.reduce(0, +),
                              substitutions: rows.map { $0[keyPath: k].substitutions }.reduce(0, +),
                              deletions: rows.map { $0[keyPath: k].deletions }.reduce(0, +),
                              insertions: rows.map { $0[keyPath: k].insertions }.reduce(0, +))
        }
        return (sum(\.stream), sum(\.offline))
    }

    static let columns = ["clip", "seconds", "ref_words", "stream_wer", "offline_wer", "dropped_words",
                          "dropped_rate", "inserted_words", "substituted_words", "lag_p50_ms", "lag_p95_ms",
                          "decode_p50_ms", "decode_p95_ms", "rtf", "cpu_per_audio_s", "passes",
                          "stream_text", "offline_text"]

    private static func csv(_ rows: [Row]) -> String {
        func f(_ x: Double?, _ digits: Int = 3) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "" }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func line(id: String, seconds: Double, s: Scoring.Alignment, o: Scoring.Alignment,
                  lags: [Double], decodes: [Double], cpu: Double, passes: Int, st: String, ot: String) -> String {
            [id, f(seconds, 2), "\(s.reference)", f(s.wer), f(o.wer), "\(s.deletions)",
             f(s.reference == 0 ? 0 : Double(s.deletions) / Double(s.reference)),
             "\(s.insertions)", "\(s.substitutions)",
             f(Scoring.percentile(lags, 50), 0), f(Scoring.percentile(lags, 95), 0),
             f(Scoring.percentile(decodes, 50), 0), f(Scoring.percentile(decodes, 95), 0),
             f(decodes.reduce(0, +) / 1000 / seconds), f(cpu / seconds), "\(passes)", q(st), q(ot)]
                .joined(separator: ",")
        }
        var out = [columns.joined(separator: ",")]
        for r in rows {
            out.append(line(id: r.id, seconds: r.seconds, s: r.stream, o: r.offline, lags: r.lags,
                            decodes: r.decodes, cpu: r.cpuSeconds, passes: r.passes,
                            st: r.streamText, ot: r.offlineText))
        }
        let all = total(rows)
        out.append(line(id: "ALL", seconds: rows.map(\.seconds).reduce(0, +), s: all.stream, o: all.offline,
                        lags: rows.flatMap(\.lags), decodes: rows.flatMap(\.decodes),
                        cpu: rows.map(\.cpuSeconds).reduce(0, +), passes: rows.map(\.passes).reduce(0, +),
                        st: "", ot: ""))
        return out.joined(separator: "\n") + "\n"
    }

    private static func writeLog(clip: Manifest.Clip, session: StreamingSession, offline: String,
                                 row: Row, to url: URL) throws {
        func words(_ ws: [Word]) -> [[Any]] {
            ws.map { [$0.text.trimmingCharacters(in: .whitespaces), r3($0.start), r3($0.end)] }
        }
        var lines: [[String: Any]] = [[
            "clip": clip.id, "reference": clip.text, "seconds": r3(row.seconds),
            "tick_ms": 350, "trim_after_s": session.streamer.config.trimAfter.isFinite
                ? session.streamer.config.trimAfter : -1,
            "context_s": session.streamer.config.context, "decoding": SelfTest.decodingArg().rawValue,
        ]]
        for p in session.passes {
            lines.append(["audio_end": r3(p.audioEnd), "window_start": r3(p.windowStart),
                          "decode_ms": Int(p.decodeMs.rounded()), "final": p.final,
                          "hypothesis": words(p.hypothesis), "committed": words(p.committed)])
        }
        lines.append(["streamed": row.streamText, "offline": offline,
                      "stream_wer": r3(row.stream.wer), "offline_wer": r3(row.offline.wer)])
        let text = try lines.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Timing columns depend on what else the machine is doing, so the run
    /// records the 1-minute load average at its start and end.
    private static func runInfo(decoding: Decoding, config: WhisperStreamer.Config, clips: Int,
                                load: (Double, Double)) throws -> String {
        let model = ModelLocator.baseEN()
        let encoder = model.map {
            $0.deletingLastPathComponent().appendingPathComponent("ggml-base.en-encoder.mlmodelc").path
        }
        let info: [String: Any] = [
            "model": "ggml-base.en.bin",
            "model_sha256": model.flatMap { sha256($0) } ?? "missing",
            "coreml_encoder": encoder.map { FileManager.default.fileExists(atPath: $0) } ?? false,
            "decoding": decoding.rawValue,
            "trim_after_s": config.trimAfter.isFinite ? config.trimAfter : -1,
            "context_s": config.context,
            "tick_ms": 350,
            "clips": clips,
            "machine": sysctl("hw.model") + ", " + sysctl("machdep.cpu.brand_string"),
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "load_average_start": r3(load.0),
            "load_average_end": r3(load.1),
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - helpers

    private static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    private static func loadAverage() -> Double {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) > 0 ? l[0] : -1
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func sha256(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: " ").first.map(String.init)
    }
}
