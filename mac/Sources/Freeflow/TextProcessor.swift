import Foundation

/// One edit to apply to the focused field. `insert` types text; `delete`
/// backspaces N characters (bounded to what THIS utterance typed, so it can
/// never eat the user's pre-existing text).
enum TextOp: Equatable {
    case insert(String)
    case delete(Int)
}

/// Transforms the committed word stream on its way to the keyboard:
///   • filler removal ("um", "uh"…)                    — default on
///   • spoken formatting ("new line", "new paragraph")  — default on
///   • deletion command ("scratch that" / "delete that")— default on
///   • custom vocabulary correction (neuro → neural…)   — always
///   • spoken punctuation ("period", "question mark"…)  — default off
///   • light auto-capitalization at sentence starts     — default on
///
/// It is STATEFUL: whisper commits words one chunk at a time, and two-word
/// commands ("new line") straddle chunks, so it holds a one-word lookahead. It
/// also tracks **pauses** (gaps between committed word timestamps): a pause marks
/// a phrase boundary, so "scratch that" stops there even when Whisper forgot the
/// sentence period — otherwise "scratch that" could wipe a whole paragraph.
/// Pure and deterministic — `--test-text` verifies it fully with no audio.
final class TextProcessor {
    struct Config {
        var filler = true
        var commands = true
        var punctuation = false
        var autoCap = true
        var vocab: [String: String] = [:]   // normalized key → replacement
    }
    var config: Config

    /// A gap this long before a word is treated as a phrase boundary.
    static let pauseSeconds = 0.35

    static let fillerWords: Set<String> = [
        "um", "uh", "uhh", "uhm", "umm", "er", "err", "erm", "hmm", "mm", "mhm",
    ]
    static let punctuationWords: [String: String] = [
        "period": ".", "comma": ",", "colon": ":", "semicolon": ";",
        "hyphen": "-", "dash": "—", "ellipsis": "…",
    ]

    init(config: Config = Config()) { self.config = config; reset() }

    // MARK: streaming state
    /// A starter word held for lookahead. `atStart` = it began at a boundary
    /// (a sentence end before it, the utterance start, or a timestamp pause).
    private struct Held { let text: String; let atStart: Bool }
    private var pending: Held?
    private var suppressLeadingSpace = true
    private var atSentenceStart = true
    private var lastEnd = -1.0                 // end time of the previous word (for gap calc)
    private(set) var emitted = ""              // all text inserted this utterance
    private var boundaries = [0]               // emitted-offsets where "scratch that" may stop
    private var emittedWords: [(start: Int, norm: String)] = []   // word spans, for multi-word vocab
    private var multiVocab: [(words: [String], replacement: String)] = []  // ≥2-word keys, longest first

    func reset() {
        pending = nil; pendingCmd = nil; suppressLeadingSpace = true; atSentenceStart = true
        lastEnd = -1; emitted = ""; boundaries = [0]; emittedWords = []
        // Split multi-word vocab keys out once per utterance (matched on Whisper's
        // OUTPUT words, which is what the user sees and corrects).
        multiVocab = config.vocab.compactMap { (k, v) -> (words: [String], replacement: String)? in
            let ws = k.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
            return ws.count >= 2 ? (words: ws, replacement: v) : nil
        }.sorted { $0.words.count > $1.words.count }
    }

    func feed(_ words: [Word]) -> [TextOp] {
        var ops: [TextOp] = []
        for w in words {
            let pause = lastEnd >= 0 && (w.start - lastEnd) >= Self.pauseSeconds
            lastEnd = w.end
            ops += resolvePendingCommand(before: w.text, pause: pause)
            ops += step(w.text, pause: pause)
        }
        return coalesce(ops)
    }

    /// Utterance ended — an unresolved command fires (end of utterance IS a
    /// boundary), then emit any word still held for lookahead.
    func flush() -> [TextOp] {
        var ops: [TextOp] = []
        if let pc = pendingCmd { pendingCmd = nil; ops += emit(pc.phrase) }
        if let held = pending { pending = nil; ops += emitWord(held.text, pause: held.atStart) }
        return coalesce(ops)
    }

    // MARK: - core

    private enum Phrase {
        case newline, paragraph, deleteSentence, punct(String)
        /// Punctuation is said continuously; formatting/deletion must be deliberate.
        var isCommand: Bool { if case .punct = self { return false }; return true }
    }
    /// A command matched at a boundary but not yet confirmed isolated — waiting to
    /// see whether Whisper starts a new sentence after it.
    private struct PendingCmd { let phrase: Phrase; let first: String; let second: String; let firstAtStart: Bool }
    private var pendingCmd: PendingCmd?

    private func step(_ tok: String, pause: Bool) -> [TextOp] {
        guard let held = pending else { return startToken(tok, pause: pause) }
        pending = nil
        if let phrase = twoWord(held.text, tok) {
            if !phrase.isCommand { return emit(phrase) }           // punctuation always fires
            if held.atStart {
                // Isolated already (Whisper punctuated it: "…that.")? Fire now.
                // Otherwise defer until we see if a new sentence starts after it.
                if endsSentence(tok) { return emit(phrase) }
                pendingCmd = PendingCmd(phrase: phrase, first: held.text, second: tok, firstAtStart: held.atStart)
                return []
            }
        }
        return emitWord(held.text, pause: held.atStart) + startToken(tok, pause: pause)
    }

    /// A command's isolation is confirmed by the word AFTER it: Whisper capitalizes
    /// the next word (or there's a pause) when the command was its own sentence
    /// ("New line. Here…"), but keeps it lowercase in a noun phrase ("New line
    /// managers"). Fire iff isolated; otherwise the two words were literal text.
    private func resolvePendingCommand(before next: String, pause: Bool) -> [TextOp] {
        guard let pc = pendingCmd else { return [] }
        pendingCmd = nil
        if pause || startsSentence(next) { return emit(pc.phrase) }
        return emitWord(pc.first, pause: pc.firstAtStart) + emitWord(pc.second, pause: false)
    }

    private func startToken(_ tok: String, pause: Bool) -> [TextOp] {
        // A command begins at a boundary: a sentence just ended, the utterance is
        // starting, or (as a bonus signal) the timestamps show a real pause.
        if isStarter(norm(tok)) { pending = Held(text: tok, atStart: atSentenceStart || pause); return [] }
        return emitWord(tok, pause: pause)
    }

    private func isStarter(_ n: String) -> Bool {
        (config.commands && ["new", "next", "scratch", "delete"].contains(n))
            || (config.punctuation && ["question", "exclamation", "full"].contains(n))
    }

    private func twoWord(_ a: String, _ b: String) -> Phrase? {
        let (x, y) = (norm(a), norm(b))
        if config.commands {
            switch (x, y) {
            case ("new", "line"), ("next", "line"):            return .newline
            case ("new", "paragraph"), ("new", "paragraphs"):  return .paragraph
            case ("scratch", "that"), ("delete", "that"):      return .deleteSentence
            default: break
            }
        }
        if config.punctuation {
            switch (x, y) {
            case ("question", "mark"):                              return .punct("?")
            case ("exclamation", "mark"), ("exclamation", "point"): return .punct("!")
            case ("full", "stop"):                                  return .punct(".")
            default: break
            }
        }
        return nil
    }

    private func emit(_ phrase: Phrase) -> [TextOp] {
        switch phrase {
        case .newline:   return newline("\n")
        case .paragraph: return newline("\n\n")
        case .punct(let p): return punctuation(p)
        case .deleteSentence:
            let target = boundaries.last(where: { $0 < emitted.count }) ?? 0
            let n = emitted.count - target
            guard n > 0 else { return [] }
            emitted.removeLast(n)
            boundaries.removeAll { $0 > emitted.count }
            emittedWords.removeAll { $0.start >= emitted.count }
            markBoundary()
            suppressLeadingSpace = emitted.isEmpty || emitted.hasSuffix("\n")
            atSentenceStart = true
            return [.delete(n)]
        }
    }

    private func newline(_ s: String) -> [TextOp] {
        emitted += s; suppressLeadingSpace = true; atSentenceStart = true; markBoundary()
        emittedWords = []                        // a term can't span a line break
        return [.insert(s)]
    }

    private func punctuation(_ p: String) -> [TextOp] {
        emitted += p
        atSentenceStart = ".!?".contains(p)
        suppressLeadingSpace = false
        if atSentenceStart { markBoundary() }
        return [.insert(p)]
    }

    private func emitWord(_ rawTok: String, pause: Bool) -> [TextOp] {
        if pause { markBoundary() }              // a real pause precedes this word → a place to stop deleting
        let key = norm(rawTok)
        if config.filler, Self.fillerWords.contains(key) { return [] }
        if config.punctuation, let p = Self.punctuationWords[key] { return punctuation(p) }

        var core = rawTok.trimmingCharacters(in: .whitespaces)
        if let replacement = config.vocab[key] { core = replacement }   // single-word correction
        if config.autoCap, atSentenceStart { core = capitalizeFirst(core) }

        let out = suppressLeadingSpace ? core : " " + core
        suppressLeadingSpace = false
        if let last = core.last { atSentenceStart = ".!?".contains(last) }
        emittedWords.append((start: emitted.count, norm: key))
        emitted += out
        if atSentenceStart { markBoundary() }    // this word ended a sentence
        var ops: [TextOp] = [.insert(out)]
        if let fix = applyMultiVocab() { ops += fix }   // multi-word correction (backspace + retype)
        return ops
    }

    /// After emitting a word, if the last N emitted words match a multi-word vocab
    /// key, backspace them and type the replacement — the same safe delete path as
    /// "scratch that", bounded to text we just typed.
    private func applyMultiVocab() -> [TextOp]? {
        for entry in multiVocab where emittedWords.count >= entry.words.count {
            let tail = emittedWords.suffix(entry.words.count)
            guard tail.map(\.norm) == entry.words else { continue }
            let startPos = tail.first!.start
            let n = emitted.count - startPos
            let firstChar = emitted[emitted.index(emitted.startIndex, offsetBy: startPos)]
            let out = (firstChar == " " ? " " : "") + entry.replacement
            emitted.removeLast(n)
            emitted += out
            emittedWords.removeLast(entry.words.count)
            emittedWords.append((start: startPos, norm: norm(entry.replacement)))
            boundaries.removeAll { $0 > emitted.count }
            if let last = entry.replacement.last { atSentenceStart = ".!?".contains(last) }
            return [.delete(n), .insert(out)]
        }
        return nil
    }

    // MARK: - helpers

    /// Record the current end of `emitted` as a place "scratch that" may stop.
    private func markBoundary() {
        if boundaries.last != emitted.count { boundaries.append(emitted.count) }
    }

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            .lowercased()
    }

    /// Did Whisper end a sentence on this token (…that. / …that? / …that!)?
    private func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?".contains(last)
    }

    /// Does this word begin a new sentence (Whisper capitalized it)? The signal
    /// that a preceding command was said in isolation.
    private func startsSentence(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return false }
        return c.isUppercase
    }

    private func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private func coalesce(_ ops: [TextOp]) -> [TextOp] {
        var out: [TextOp] = []
        for op in ops {
            if case .insert(let s) = op, case .insert(let prev)? = out.last {
                out[out.count - 1] = .insert(prev + s)
            } else {
                out.append(op)
            }
        }
        return out
    }
}
