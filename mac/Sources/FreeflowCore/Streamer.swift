import Foundation

/// One timestamped word from the decoder.
public struct Word: Equatable {
    public let text: String   // raw, with a leading space (join-ready) for English
    public let start: Double  // seconds
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

/// Whisper was trained on subtitles, so on non-speech it emits sound-event
/// annotations ("[BLANK_AUDIO]", "(music)", "♪") or bare punctuation. None of
/// that is dictation.
public func isNonSpeech(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return true }
    if t.rangeOfCharacter(from: CharacterSet(charactersIn: "[]()♪*")) != nil { return true }
    return t.rangeOfCharacter(from: .alphanumerics) == nil   // bare punctuation
}

/// Turns repeated whisper.cpp passes over a growing audio window into a stream
/// of *stable* words — a Swift port of the Python engine in freeflow/stt.py:
///   • LocalAgreement-2: commit a word only when two passes agree → append-only,
///     so we never delete text we've already typed (the Apple-Speech bug).
///   • n-gram text dedup at the boundary (whisper.cpp timestamps are coarse).
///   • buffer trimming: drop committed audio so long dictations stay fast.
///   • non-speech token filtering ([BLANK_AUDIO], (music), bare punctuation).
public final class WhisperStreamer {
    public struct Config: Equatable {
        public var trimAfter: Double   // trim once this much committed audio piles up
        public var context: Double     // keep this much committed audio for context

        public init(trimAfter: Double, context: Double) {
            self.trimAfter = trimAfter; self.context = context
        }

        // Keep the transcription window SMALL. Large windows both slow whisper.cpp
        // down (falling behind real-time) and make its greedy decoder skip phrases —
        // which buffer-trimming then makes permanent. Trimming aggressively to a
        // short window is faster AND drops far less. (was 8.0 / 2.0 → caused ~2s skips.)
        public static let shipped = Config(trimAfter: 3.0, context: 1.5)
    }

    public let config: Config
    private var committed: [Word] = []
    private var buffer: [Word] = []     // previous pass's still-unconfirmed tail
    private var lastTime = 0.0          // end time of the last committed word
    public private(set) var offset = 0.0   // seconds trimmed off the front

    private let sampleRate = 16000

    public init(config: Config = .shipped) { self.config = config }

    /// All committed words this utterance (for diagnostics / gap analysis).
    public var committedWords: [Word] { committed }
    /// The previous pass's words that are not yet confirmed.
    public var pendingWords: [Word] { buffer }

    public func reset() {
        committed = []; buffer = []; lastTime = 0; offset = 0
    }

    /// First sample of the window we still transcribe (everything before is trimmed).
    public func windowStartSample() -> Int { Int(offset * Double(sampleRate)) }

    /// One live pass. `window` is the decoder's words over the current window,
    /// with times relative to the window start, and `duration` the window's
    /// length in seconds when known. Returns the newly-stable words.
    public func process(window: [Word], duration: Double? = nil) -> [Word] {
        let words = agree(words: toWords(window, duration))
        // Bound per-tick cost. Trim from the last committed word's START: its
        // end is often stretched toward the window end, and cutting there would
        // cut into words that are not committed yet.
        if let last = committed.last, lastTime - offset > config.trimAfter {
            offset = max(offset, last.start - config.context)
        }
        return words
    }

    /// Final pass on stop: commit whatever's left in the tail.
    public func finalize(window: [Word], duration: Double? = nil) -> [Word] {
        let remaining = stripCommitted(toWords(window, duration))
        if let last = remaining.last { lastTime = last.end }
        committed.append(contentsOf: remaining)
        return remaining
    }

    // MARK: - internals
    /// Non-speech dropped, times made absolute. whisper.cpp occasionally reports
    /// a word ending far past the audio (30 s in a 2 s window); one such time
    /// would become the commit point and swallow every later word, so times are
    /// clamped to the window.
    private func toWords(_ window: [Word], _ duration: Double?) -> [Word] {
        let limit = duration ?? .infinity
        return window.compactMap { w in
            guard !isNonSpeech(w.text) else { return nil }
            let end = min(max(w.end, 0), limit), start = min(max(w.start, 0), end)
            return Word(text: " " + w.text.trimmingCharacters(in: .whitespaces),
                        start: start + offset, end: end + offset)
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

    /// Drop the words of this pass that re-hear what is already committed.
    ///
    /// whisper.cpp's word times drift by up to a second between passes, and the
    /// last word of a pass is stretched to the end of the window. So the cut is
    /// found by TEXT first: the longest run of the last committed words that
    /// this pass repeats, taking the occurrence nearest in time when the run
    /// appears twice. Only when the pass repeats none of them does the old
    /// time rule apply (keep words starting after the last committed end),
    /// followed by the n-gram check for a boundary repeat.
    private func stripCommitted(_ input: [Word]) -> [Word] {
        guard !committed.isEmpty, !input.isEmpty else { return input }
        if let cut = anchor(in: input) { return Array(input[cut...]) }
        var words = input.filter { $0.start > lastTime - 0.1 }
        if !words.isEmpty {
            let tail = committed.suffix(6).map { key($0.text) }
            let head = words.prefix(6).map { key($0.text) }
            for k in stride(from: min(tail.count, head.count), through: 1, by: -1) {
                if Array(tail.suffix(k)) == Array(head.prefix(k)) {
                    words = Array(words.dropFirst(k)); break
                }
            }
        }
        return words
    }

    /// Index just past the committed tail's re-hearing in `words`, or nil.
    private func anchor(in words: [Word]) -> Int? {
        let tail = committed.suffix(Self.anchorWords).map { key($0.text) }
        let keys = words.map { key($0.text) }
        for k in stride(from: tail.count, through: 1, by: -1) {
            guard keys.count >= k else { continue }
            let run = Array(tail.suffix(k))
            let tolerance = k == 1 ? 1.0 : 2.0    // a lone word must sit close in time
            var best: (cut: Int, dt: Double)?
            for p in 0...(keys.count - k) where Array(keys[p..<(p + k)]) == run {
                let dt = abs(words[p + k - 1].end - lastTime)
                if dt <= tolerance, dt < (best?.dt ?? .infinity) { best = (p + k, dt) }
            }
            if let best { return best.cut }
        }
        return nil
    }

    static let anchorWords = 4

    /// Comparison key for matching re-heard words: case and punctuation drop out
    /// ("you?" re-heard as "you." is the same word).
    private func key(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }
            .map(String.init).joined()
    }

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
