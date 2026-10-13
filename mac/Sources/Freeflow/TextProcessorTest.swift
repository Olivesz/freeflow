import Foundation

/// Hidden mode: `Freeflow --test-text`. Runs the TextProcessor through a battery
/// of cases and prints PASS/FAIL — proves the vocab/filler/command pipeline with
/// no microphone, the same way --selftest proves the streaming port.
enum TextProcessorTest {
    static func run() {
        var passed = 0, failed = 0

        func applyOps(_ ops: [TextOp], to field: inout String) {
            for op in ops {
                switch op {
                case .insert(let s): field += s
                case .delete(let n): field = String(field.dropLast(n))
                }
            }
        }

        /// Simulate whisper committing `words` as contiguous (no-pause) tokens,
        /// optionally split across ticks; return the resulting field text.
        func stream(_ words: [String], config: TextProcessor.Config, ticks: Int = 1) -> String {
            let p = TextProcessor(config: config)
            var field = "", t = 0.0
            let toks: [Word] = words.map { w in
                let word = Word(text: " " + w, start: t, end: t + 0.3); t += 0.3; return word
            }
            let size = max(1, Int(ceil(Double(toks.count) / Double(ticks))))
            var i = 0
            while i < toks.count {
                applyOps(p.feed(Array(toks[i..<min(i + size, toks.count)])), to: &field)
                i += size
            }
            applyOps(p.flush(), to: &field)
            return field
        }

        /// Like `stream`, but each item carries an explicit pause (seconds) before
        /// it — for exercising pause-scoped "scratch that".
        func streamP(_ items: [(String, Double)], config: TextProcessor.Config) -> String {
            let p = TextProcessor(config: config)
            var field = "", t = 0.0
            let toks: [Word] = items.map { (w, gap) in
                t += gap
                let word = Word(text: " " + w, start: t, end: t + 0.3); t += 0.3; return word
            }
            applyOps(p.feed(toks), to: &field)
            applyOps(p.flush(), to: &field)
            return field
        }

        func check(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            print("\(ok ? "✓" : "✗") \(name)")
            if !ok { print("    got:  \(esc(got))\n    want: \(esc(want))"); failed += 1 } else { passed += 1 }
        }

        let on = TextProcessor.Config()                       // defaults: filler+commands+autoCap on, punct off
        var punct = TextProcessor.Config(); punct.punctuation = true
        var plain = TextProcessor.Config(); plain.filler = false; plain.commands = false; plain.autoCap = false
        var vocab = TextProcessor.Config(); vocab.vocab = ["neuro": "neural", "gpt": "GPT"]

        // Spacing: no leading space at the start of the field (a real fix — the old
        // path injected a stray leading space); single spaces between words.
        check("no leading space + autocap", stream(["hello", "there"], config: on), "Hello there")
        check("no leading space even when plain", stream(["hello", "world"], config: plain), "hello world")

        // Filler removal (safe set only).
        check("drops um/uh", stream(["um", "so", "uh", "yeah"], config: on), "So yeah")
        check("keeps 'like'", stream(["i", "like", "this"], config: on), "I like this")

        // Formatting commands fire only when ISOLATED — their own sentence, which is
        // how Whisper renders a deliberate "…text. New line. …text" (period + capital).
        check("new line fires when isolated",
              streamP([("done.", 0), ("new", 0.5), ("line.", 0), ("next", 0)], config: on), "Done.\nNext")
        check("new paragraph fires when isolated",
              streamP([("a.", 0), ("new", 0.5), ("paragraph.", 0), ("b", 0)], config: on), "A.\n\nB")
        // FALSE-POSITIVE GUARDS: not isolated → literal text.
        check("'new line' mid-sentence is NOT a command",
              stream(["add", "a", "new", "line", "of", "code"], config: on), "Add a new line of code")
        check("'new line' noun phrase at a sentence start is NOT a command",
              streamP([("i", 0), ("finished.", 0), ("new", 0), ("line", 0), ("managers", 0)], config: on),
              "I finished. New line managers")
        check("'delete that' mid-sentence is NOT a command",
              stream(["please", "delete", "that", "file"], config: on), "Please delete that file")
        check("command word alone is literal",
              stream(["buy", "a", "new", "phone"], config: on), "Buy a new phone")

        // A command split across two feed() calls still fires (state carried on the held word).
        do {
            let p = TextProcessor(config: on); var f = ""
            applyOps(p.feed([Word(text: " done.", start: 0, end: 0.3)]), to: &f)
            applyOps(p.feed([Word(text: " new", start: 0.8, end: 1.1),
                             Word(text: " line.", start: 1.1, end: 1.4)]), to: &f)
            applyOps(p.feed([Word(text: " ok", start: 1.9, end: 2.2)]), to: &f)
            applyOps(p.flush(), to: &f)
            check("command across feed() calls", f, "Done.\nOk")
        }

        // Custom vocabulary (autoCap on by default, so first word capitalizes).
        check("vocab single word", stream(["neuro", "engine"], config: vocab), "Neural engine")
        check("vocab replaces mid-sentence", stream(["the", "gpt", "model"], config: vocab), "The GPT model")

        // Multi-word vocabulary — keyed on Whisper's OUTPUT words (what the user sees
        // and corrects), backspace-and-retype. Whisper renders "open ai" as "open eye".
        var mv = TextProcessor.Config(); mv.vocab = ["open eye": "OpenAI", "s code": "VS Code"]
        check("multi-word vocab replaces two words",
              stream(["i", "use", "open", "eye", "daily"], config: mv), "I use OpenAI daily")
        check("multi-word vocab is robust to Whisper punctuation (S, Code)",
              stream(["we", "use", "s", "code", "here"], config: mv), "We use VS Code here")
        check("multi-word vocab fires only on the adjacent full key",
              stream(["open", "the", "eye"], config: mv), "Open the eye")
        // Streaming reality: the key's words arrive in SEPARATE feed() calls (ticks).
        do {
            let p = TextProcessor(config: mv); var f = ""
            applyOps(p.feed([Word(text: " i", start: 0, end: 0.3),
                             Word(text: " use", start: 0.3, end: 0.6),
                             Word(text: " open", start: 0.6, end: 0.9)]), to: &f)   // "open" this tick
            applyOps(p.feed([Word(text: " eye", start: 0.9, end: 1.2)]), to: &f)     // "eye" completes it next tick
            applyOps(p.flush(), to: &f)
            check("multi-word vocab fires across feed() calls", f, "I use OpenAI")
        }
        // No state carryover: a second utterance after reset() starts clean.
        do {
            let p = TextProcessor(config: on); var f1 = "", f2 = ""
            applyOps(p.feed([Word(text: " hello.", start: 0, end: 0.3)]), to: &f1); applyOps(p.flush(), to: &f1)
            p.reset()
            applyOps(p.feed([Word(text: " world", start: 0, end: 0.3)]), to: &f2); applyOps(p.flush(), to: &f2)
            check("second utterance starts clean after reset", f2, "World")
        }

        // Spoken punctuation (opt-in).
        check("period + capitalize next", stream(["hello", "period", "world"], config: punct), "Hello. World")
        check("two-word question mark", stream(["really", "question", "mark"], config: punct), "Really?")
        check("punct off leaves the word", stream(["say", "period", "now"], config: on), "Say period now")

        // Deletion — must be its OWN sentence ("…scratch that."), so a mid-sentence
        // "delete that file" can never nuke text. Whisper punctuates the pause reliably
        // even when its word timestamps show a 0.00s gap (the real case-C failure).
        check("scratch that clears when there's no earlier boundary",
              streamP([("hello", 0), ("world", 0), ("scratch", 0.5), ("that.", 0), ("again", 0.5)], config: on),
              "Again")
        check("scratch that keeps prior sentence",
              streamP([("one", 0), ("period", 0), ("two", 0), ("scratch", 0.5), ("that.", 0), ("three", 0.5)],
                      config: punct),
              "One. Three")
        check("scratch that stops at the boundary, not the paragraph",
              streamP([("the", 0), ("engine", 0), ("is", 0), ("fast", 0),
                       ("actually", 0.5), ("scratch", 0.5), ("that.", 0), ("new", 0.5), ("text", 0)],
                      config: on),
              "The engine is fast New text")
        // Fires on Whisper's SENTENCE boundary even with a 0.00s timestamp gap (case C).
        check("scratch that fires on a terminator boundary, no timestamp gap",
              streamP([("red.", 0), ("scratch", 0), ("that.", 0), ("blue", 0)], config: on), "Blue")
        // SAFETY: not isolated → not a command, even right after a period.
        check("'delete that ___' after a period does NOT delete",
              streamP([("done.", 0), ("delete", 0), ("that", 0), ("file", 0)], config: on),
              "Done. Delete that file")
        check("'scratch that' mid-sentence is NOT a command",
              stream(["i", "will", "scratch", "that", "itch"], config: on), "I will scratch that itch")

        // Isolation confirmed by the NEXT word being capitalized (Whisper's real
        // signal — it often capitalizes the next word instead of ending the command
        // with a period). No period on the command itself here.
        check("new paragraph fires when the next word is capitalized",
              streamP([("intro.", 0), ("new", 0), ("paragraph", 0), ("Here", 0)], config: on),
              "Intro.\n\nHere")
        check("scratch that fires when the next word is capitalized",
              streamP([("red.", 0), ("scratch", 0), ("that", 0), ("Blue", 0)], config: on), "Blue")
        // Same words, lowercase continuation → a noun phrase, NOT a command.
        check("'scratch that' + lowercase continuation is NOT a command",
              streamP([("done.", 0), ("scratch", 0), ("that", 0), ("plan", 0)], config: on),
              "Done. Scratch that plan")
        // A deferred command at the very end of the utterance fires (utterance end = a boundary).
        check("command at end of utterance fires",
              streamP([("wrap", 0), ("up.", 0), ("new", 0), ("line", 0)], config: on), "Wrap up.\n")

        // REGRESSION GUARD: beam search SIGTRAPs whisper.cpp (exit 133) on some audio,
        // crashing the app mid-dictation. This fails the instant anyone re-enables it.
        check("app decoding is greedy, never beam (beam crashes the app)",
              Dictation.isGreedyDecoding ? "greedy" : "beam", "greedy")

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    private static func esc(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
