import Foundation

/// Tiny append-only diagnostic log at /tmp/freeflow-diag.log. Kept on while we
/// tune quality: it pinpoints the "swallowed words" bug — capture shortfall vs.
/// model skip. (Logs transcripts to /tmp; strip before a public release.)
enum Diag {
    static let path = "/tmp/freeflow-diag.log"

    static func log(_ s: String) {
        let line = s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

private func r1(_ v: Double) -> String { String(format: "%.1f", v) }
private func r2(_ v: Double) -> String { String(format: "%.2f", v) }
private func r3(_ v: Float) -> String { String(format: "%.3f", v) }

extension Diag {
    /// Summarize one utterance: wall vs captured seconds (capture drops), max
    /// transcribe time (CPU pressure), and gaps in committed word timestamps
    /// that coincided with speech-level energy (model skips).
    static func utterance(fullSamples: Int, wall: Double, maxTranscribeMs: Int,
                          ticks: Int, words: [Word], rmsIn: (Double, Double) -> Float) {
        let captured = Double(fullSamples) / 16000.0
        log("── utterance @ \(Date()) ──")
        log("wall=\(r1(wall))s captured=\(r1(captured))s  shortfall=\(r1(wall - captured))s"
            + "  maxTranscribe=\(maxTranscribeMs)ms  ticks=\(ticks)  words=\(words.count)")
        if words.count >= 2 {
            for i in 1..<words.count {
                let gap = words[i].start - words[i - 1].end
                guard gap > 0.7 else { continue }
                let energy = rmsIn(words[i - 1].end, words[i].start)
                let verdict = energy > 0.02 ? "⚠︎ SPEECH DROPPED" : "(pause)"
                log("  gap \(r2(words[i - 1].end))→\(r2(words[i].start))s"
                    + " (\(r2(gap))s) rms=\(r3(energy)) \(verdict)"
                    + "   …\(words[i - 1].text) / \(words[i].text)…")
            }
        }
        log("text:" + words.map(\.text).joined())
    }
}
