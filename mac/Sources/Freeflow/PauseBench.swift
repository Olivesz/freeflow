import Foundation
import FreeflowCore

/// Hidden mode: `Freeflow --pause-bench <manifest.json> --out <file.csv>
/// [--pause s] [--gains 1,0.12] [--clips a,b]`.
///
/// Does auto-stop cut a speaker off while they pause to think? For each clip
/// it finds a word boundary mid-sentence (from an offline decode's timestamps),
/// inserts a pause there, lays quiet room noise under everything, optionally
/// scales the speech down to a quiet-mic level, and replays it tick by tick
/// through the same session the app runs. Every tick feeds two endpointers on
/// the same pass stream — the one that shipped (fixed 0.006 floor, one 1.5 s
/// timeout) and the current one — and records where each would have stopped:
///
///   cut      stopped before the speaker came back after the pause
///   late     stopped during the second half (also a cut-off)
///   ok       stopped after the last word; `after_s` is how long after
///   open     never stopped within the tail
enum PauseBench {
    static let graceMs = 400
    static let tailS = 6.0, noiseRMS: Float = 0.001
    static var silenceMs: Int { arg("--silence").flatMap(Int.init) ?? 1500 }

    static func run() -> Never {
        SelfTest.spawn {
            let a = CommandLine.arguments
            guard let mi = a.firstIndex(of: "--pause-bench"), mi + 1 < a.count,
                  let oi = a.firstIndex(of: "--out"), oi + 1 < a.count else {
                print("usage: Freeflow --pause-bench <manifest.json> --out <file.csv> [--pause s] [--gains 1,0.12] [--clips a,b]")
                exit(2)
            }
            try await go(manifest: URL(fileURLWithPath: a[mi + 1]), out: URL(fileURLWithPath: a[oi + 1]))
        }
    }

    private static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    private static func go(manifest url: URL, out: URL) async throws {
        let manifest = try JSONDecoder().decode(Bench.Manifest.self, from: Data(contentsOf: url))
        var clips = manifest.clips
        if let keep = arg("--clips").map({ Set($0.split(separator: ",").map(String.init)) }) {
            clips = clips.filter { keep.contains($0.id) }
        }
        let pauses = (arg("--pause") ?? "2").split(separator: ",").compactMap { Double($0) }
        let gains = (arg("--gains") ?? "1,0.12").split(separator: ",").compactMap { Float($0) }
        let whisper = try await SelfTest.loadDecoder(.shipped)

        var lines = ["clip,gain,pause_s,split_s,resume_s,speech_end_s,variant,outcome,stop_s,after_s,cut_after"]
        var tally: [String: [String: Int]] = [:]
        for clip in clips {
            let frames = try SelfTest.readWav(url.deletingLastPathComponent().appendingPathComponent(clip.path))
            let words = try await whisper.words(frames).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let cut = splitPoint(words, seconds: Double(frames.count) / 16000) else {
                print("\(clip.id): no mid-sentence boundary, skipped"); continue
            }
            for pauseS in pauses { for gain in gains {
                let (audio, resume, speechEnd) = build(frames, split: cut.at, pauseS: pauseS, gain: gain)
                let stops = try await replay(audio, decoder: whisper)
                for (variant, stop) in stops {
                    let outcome: String, after: String
                    switch stop {
                    case nil: outcome = "open"; after = ""
                    case let s? where s < resume: outcome = "cut"; after = ""
                    case let s? where s < speechEnd: outcome = "late"; after = ""
                    case let s?: outcome = "ok"; after = String(format: "%.2f", s - speechEnd)
                    }
                    tally["pause \(pauseS) s, gain \(gain), \(variant)", default: [:]][outcome, default: 0] += 1
                    lines.append([clip.id, "\(gain)", "\(pauseS)", f(cut.at), f(resume), f(speechEnd), variant,
                                  outcome, stop.map(f) ?? "", after, "\"\(cut.after)\""].joined(separator: ","))
                }
                print("\(clip.id) pause \(pauseS) gain \(gain) split after \"\(cut.after)\": " +
                      stops.map { "\($0.0)=\($0.1.map(f) ?? "never")" }.joined(separator: " ") +
                      String(format: "  (resume %.2f, end %.2f)", resume, speechEnd))
            } }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        for (k, v) in tally.sorted(by: { $0.key < $1.key }) {
            print(k + ": " + ["cut", "late", "ok", "open"].map { "\($0) \(v[$0] ?? 0)" }.joined(separator: ", "))
        }
    }

    /// A gap between two words in the middle half of the clip where the first
    /// word doesn't end a sentence: the speaker is mid-thought.
    static func splitPoint(_ words: [Word], seconds: Double) -> (at: Double, after: String)? {
        let mid = words.indices.dropLast().filter {
            let t = words[$0].end
            return t > seconds * 0.25 && t < seconds * 0.75 && !words[$0].endsSentence
        }
        guard let i = mid.min(by: { abs(words[$0].end - seconds / 2) < abs(words[$1].end - seconds / 2) })
        else { return nil }
        return ((words[i].end + words[i + 1].start) / 2, words[i].text.trimmingCharacters(in: .whitespaces))
    }

    /// Speech scaled by `gain`, a pause inserted at `split`, a tail of room
    /// noise after, and the same steady noise under all of it.
    static func build(_ x: [Float], split: Double, pauseS: Double, gain: Float)
        -> (audio: [Float], resume: Double, speechEnd: Double) {
        let s = Int(split * 16000), p = Int(pauseS * 16000), t = Int(tailS * 16000)
        var y = x[..<s].map { $0 * gain } + [Float](repeating: 0, count: p)
            + x[s...].map { $0 * gain } + [Float](repeating: 0, count: t)
        var rng: UInt64 = 0x9E3779B97F4A7C15                  // fixed seed: same noise every run
        for i in y.indices {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(rng >> 40) / Float(1 << 24)           // uniform [0,1)
            y[i] += (u * 2 - 1) * noiseRMS * 1.732              // uniform with this RMS
        }
        return (y, Double(s + p) / 16000, Double(x.count + p) / 16000)
    }

    /// Live replay: one tick per 350 ms of audio, both endpointers judging the
    /// same ticks exactly as Dictation.loop does. Returns each one's stop time.
    static func replay(_ audio: [Float], decoder whisper: WordDecoder) async throws -> [(String, Double?)] {
        let session = StreamingSession(config: SelfTest.configArg())
        var shipped = SilenceEndpointer(tickMs: SelfTest.tickMs, graceMs: graceMs,
                                        adaptive: false, holdOpenSentences: false)
        var current = SilenceEndpointer(tickMs: SelfTest.tickMs, graceMs: graceMs)
        var stopShipped: Double?, stopCurrent: Double?
        var k = SelfTest.tickSamples
        while k <= audio.count, stopShipped == nil || stopCurrent == nil {
            let full = Array(audio[..<k])
            var level: Float?, quietest: Float?
            if full.count - session.streamer.windowStartSample() >= StreamingSession.minWindowSamples {
                _ = try await session.tick(audio: full, decoder: whisper)
                let last = full.suffix(SelfTest.tickSamples)
                level = Audio.rms(last); quietest = Audio.quietestFrameRMS(last)
            }
            let now = Double(k) / 16000, open = session.sentenceOpen
            if stopShipped == nil, shipped.tick(rms: level, silenceMs: silenceMs, sentenceOpen: open) { stopShipped = now }
            if stopCurrent == nil, current.tick(rms: level, quietest: quietest, silenceMs: silenceMs,
                                                sentenceOpen: open) {
                stopCurrent = now
                if ProcessInfo.processInfo.environment["PB_DEBUG"] != nil {
                    let tail = session.passes.suffix(3).map { p in
                        String(format: "[end %.2f] ", p.audioEnd) + p.hypothesis.suffix(4).map { "«\($0.text)»" }.joined(separator: " ")
                    }
                    print("  current stop @\(now) open=\(open) last passes:\n    " + tail.joined(separator: "\n    "))
                }
            }
            k += SelfTest.tickSamples
        }
        if stopCurrent == nil, ProcessInfo.processInfo.environment["PB_DEBUG"] != nil {
            let tail = session.passes.suffix(3).map { p in
                String(format: "[end %.2f] ", p.audioEnd) + p.hypothesis.suffix(4).map { "«\($0.text)»" }.joined(separator: " ")
            }
            print("  current never stopped, open=\(session.sentenceOpen), \(session.passes.count) passes; last:\n    "
                  + tail.joined(separator: "\n    "))
        }
        return [("shipped", stopShipped), ("current", stopCurrent)]
    }

    private static func f(_ x: Double) -> String { String(format: "%.2f", x) }
}
