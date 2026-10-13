import Foundation
import SwiftWhisper

/// Turns repeated whisper.cpp passes over a growing audio window into a stream
/// of *stable* words — a Swift port of the validated Python engine:
///   • LocalAgreement-2: commit a word only when two passes agree → append-only,
///     so we never delete text we've already typed (the Apple-Speech bug).
///   • n-gram text dedup at the boundary (whisper.cpp timestamps are coarse).
///   • buffer trimming: drop committed audio so long dictations stay fast.
///   • non-speech token filtering ([BLANK_AUDIO], (music), bare punctuation).
struct Word {
    let text: String   // raw, with a leading space (join-ready) for English
    let start: Double  // seconds, absolute within the utterance
    let end: Double
}

final class WhisperStreamer {
    private var committed: [Word] = []
    private var buffer: [Word] = []     // previous pass's still-unconfirmed tail
    private var lastTime = 0.0          // end time of the last committed word
    private(set) var offset = 0.0       // seconds trimmed off the front

    private let sampleRate = 16000
    // Keep the transcription window SMALL. Large windows both slow whisper.cpp
    // down (falling behind real-time) and make its greedy decoder skip phrases —
    // which buffer-trimming then makes permanent. Trimming aggressively to a
    // short window is faster AND drops far less. (was 8.0 / 2.0 → caused ~2s skips.)
    private let trimAfter = 3.0         // trim once this much committed audio piles up
    private let context = 1.5           // keep this much committed audio for context

    /// All committed words this utterance (for diagnostics / gap analysis).
    var committedWords: [Word] { committed }

    func reset() {
        committed = []; buffer = []; lastTime = 0; offset = 0
    }

    /// First sample of the window we still transcribe (everything before is trimmed).
    func windowStartSample() -> Int { Int(offset * Double(sampleRate)) }

    /// One live pass. `segments` are whisper word-segments over the current
    /// window (times relative to the window start). Returns the newly-stable words.
    func process(window segments: [Segment]) -> [Word] {
        let words = agree(words: toWords(segments))
        if lastTime - offset > trimAfter {           // bound per-tick cost
            offset = max(offset, lastTime - context)
        }
        return words
    }

    /// Final pass on stop: commit whatever's left in the tail.
    func finalize(window segments: [Segment]) -> [Word] {
        let remaining = stripCommitted(toWords(segments))
        if let last = remaining.last { lastTime = last.end }
        committed.append(contentsOf: remaining)
        return remaining
    }

    // MARK: - internals
    private func toWords(_ segments: [Segment]) -> [Word] {
        segments.compactMap { seg in
            guard !isNonSpeech(seg.text) else { return nil }
            let t = " " + seg.text.trimmingCharacters(in: .whitespaces)
            return Word(text: t,
                        start: Double(seg.startTime) / 1000.0 + offset,   // Segment times are ms
                        end: Double(seg.endTime) / 1000.0 + offset)
        }
    }

    private func agree(words input: [Word]) -> [Word] {
        let words = stripCommitted(input)
        // LocalAgreement: commit the common prefix of this pass and the last.
        var out: [Word] = []
        var i = 0
        while i < words.count, i < buffer.count, norm(words[i].text) == norm(buffer[i].text) {
            out.append(words[i]); lastTime = words[i].end; i += 1
        }
        committed.append(contentsOf: out)
        buffer = Array(words[i...])
        return out
    }

    /// Drop words already committed — by TIME (precise) and by TEXT n-gram
    /// (catches boundary repeats from whisper.cpp's coarse timestamps).
    private func stripCommitted(_ input: [Word]) -> [Word] {
        var words = input.filter { $0.start > lastTime - 0.1 }
        if !committed.isEmpty, !words.isEmpty {
            let tail = committed.suffix(6).map { norm($0.text) }
            let head = words.prefix(6).map { norm($0.text) }
            for k in stride(from: min(tail.count, head.count), through: 1, by: -1) {
                if Array(tail.suffix(k)) == Array(head.prefix(k)) {
                    words = Array(words.dropFirst(k)); break
                }
            }
        }
        return words
    }

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func isNonSpeech(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if t.rangeOfCharacter(from: CharacterSet(charactersIn: "[]()♪*")) != nil { return true }
        return t.rangeOfCharacter(from: .alphanumerics) == nil   // bare punctuation
    }
}
