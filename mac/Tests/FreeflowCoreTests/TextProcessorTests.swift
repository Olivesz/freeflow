import FreeflowCore
import XCTest

/// The TextProcessor sits between the streamer and the keyboard. Every case
/// here is a sequence of committed words and the exact text that must end up in
/// the focused field after applying the emitted inserts and backspaces.
final class TextProcessorTests: XCTestCase {
    private let on = TextProcessor.Config()   // filler + commands + autoCap on, punctuation off
    private var punct: TextProcessor.Config { var c = on; c.punctuation = true; return c }
    private var plain: TextProcessor.Config {
        var c = on; c.filler = false; c.commands = false; c.autoCap = false; return c
    }
    private var vocab: TextProcessor.Config { var c = on; c.vocab = ["neuro": "neural", "gpt": "GPT"]; return c }
    private var multi: TextProcessor.Config { var c = on; c.vocab = ["open eye": "OpenAI", "s code": "VS Code"]; return c }

    private func apply(_ ops: [TextOp], to field: inout String) {
        for op in ops {
            switch op {
            case .insert(let s): field += s
            case .delete(let n): field = String(field.dropLast(n))
            }
        }
    }

    /// Words committed back to back (no pauses), optionally split across ticks.
    private func stream(_ words: [String], _ config: TextProcessor.Config, ticks: Int = 1) -> String {
        let p = TextProcessor(config: config)
        var field = "", t = 0.0
        let toks: [Word] = words.map { w in
            defer { t += 0.3 }
            return Word(text: " " + w, start: t, end: t + 0.3)
        }
        let size = max(1, Int(ceil(Double(toks.count) / Double(ticks))))
        var i = 0
        while i < toks.count {
            apply(p.feed(Array(toks[i..<min(i + size, toks.count)])), to: &field)
            i += size
        }
        apply(p.flush(), to: &field)
        return field
    }

    /// Each item carries the pause (seconds) before it.
    private func streamP(_ items: [(String, Double)], _ config: TextProcessor.Config) -> String {
        let p = TextProcessor(config: config)
        var field = "", t = 0.0
        let toks: [Word] = items.map { w, gap in
            t += gap
            defer { t += 0.3 }
            return Word(text: " " + w, start: t, end: t + 0.3)
        }
        apply(p.feed(toks), to: &field)
        apply(p.flush(), to: &field)
        return field
    }

    // MARK: spacing

    func testNoLeadingSpaceAndAutoCap() {
        XCTAssertEqual(stream(["hello", "there"], on), "Hello there")
    }

    func testNoLeadingSpaceWhenPlain() {
        XCTAssertEqual(stream(["hello", "world"], plain), "hello world")
    }

    // MARK: fillers

    func testDropsUmAndUh() {
        XCTAssertEqual(stream(["um", "so", "uh", "yeah"], on), "So yeah")
    }

    func testKeepsLike() {
        XCTAssertEqual(stream(["i", "like", "this"], on), "I like this")
    }

    // MARK: formatting commands fire only when isolated

    func testNewLineFiresWhenIsolated() {
        XCTAssertEqual(streamP([("done.", 0), ("new", 0.5), ("line.", 0), ("next", 0)], on), "Done.\nNext")
    }

    func testNewParagraphFiresWhenIsolated() {
        XCTAssertEqual(streamP([("a.", 0), ("new", 0.5), ("paragraph.", 0), ("b", 0)], on), "A.\n\nB")
    }

    func testNewLineMidSentenceIsLiteral() {
        XCTAssertEqual(stream(["add", "a", "new", "line", "of", "code"], on), "Add a new line of code")
    }

    func testNewLineNounPhraseAtSentenceStartIsLiteral() {
        XCTAssertEqual(streamP([("i", 0), ("finished.", 0), ("new", 0), ("line", 0), ("managers", 0)], on),
                       "I finished. New line managers")
    }

    func testDeleteThatMidSentenceIsLiteral() {
        XCTAssertEqual(stream(["please", "delete", "that", "file"], on), "Please delete that file")
    }

    func testCommandWordAloneIsLiteral() {
        XCTAssertEqual(stream(["buy", "a", "new", "phone"], on), "Buy a new phone")
    }

    func testCommandAcrossFeedCalls() {
        let p = TextProcessor(config: on); var f = ""
        apply(p.feed([Word(text: " done.", start: 0, end: 0.3)]), to: &f)
        apply(p.feed([Word(text: " new", start: 0.8, end: 1.1), Word(text: " line.", start: 1.1, end: 1.4)]), to: &f)
        apply(p.feed([Word(text: " ok", start: 1.9, end: 2.2)]), to: &f)
        apply(p.flush(), to: &f)
        XCTAssertEqual(f, "Done.\nOk")
    }

    // MARK: vocabulary

    func testVocabSingleWord() {
        XCTAssertEqual(stream(["neuro", "engine"], vocab), "Neural engine")
    }

    func testVocabMidSentence() {
        XCTAssertEqual(stream(["the", "gpt", "model"], vocab), "The GPT model")
    }

    func testMultiWordVocabReplacesTwoWords() {
        XCTAssertEqual(stream(["i", "use", "open", "eye", "daily"], multi), "I use OpenAI daily")
    }

    func testMultiWordVocabIgnoresWhisperPunctuation() {
        XCTAssertEqual(stream(["we", "use", "s", "code", "here"], multi), "We use VS Code here")
    }

    func testMultiWordVocabNeedsTheAdjacentKey() {
        XCTAssertEqual(stream(["open", "the", "eye"], multi), "Open the eye")
    }

    func testMultiWordVocabAcrossFeedCalls() {
        let p = TextProcessor(config: multi); var f = ""
        apply(p.feed([Word(text: " i", start: 0, end: 0.3), Word(text: " use", start: 0.3, end: 0.6),
                      Word(text: " open", start: 0.6, end: 0.9)]), to: &f)
        apply(p.feed([Word(text: " eye", start: 0.9, end: 1.2)]), to: &f)
        apply(p.flush(), to: &f)
        XCTAssertEqual(f, "I use OpenAI")
    }

    func testResetStartsClean() {
        let p = TextProcessor(config: on); var f1 = "", f2 = ""
        apply(p.feed([Word(text: " hello.", start: 0, end: 0.3)]), to: &f1); apply(p.flush(), to: &f1)
        p.reset()
        apply(p.feed([Word(text: " world", start: 0, end: 0.3)]), to: &f2); apply(p.flush(), to: &f2)
        XCTAssertEqual(f2, "World")
    }

    // MARK: spoken punctuation (opt-in)

    func testPeriodCapitalizesNext() {
        XCTAssertEqual(stream(["hello", "period", "world"], punct), "Hello. World")
    }

    func testTwoWordQuestionMark() {
        XCTAssertEqual(stream(["really", "question", "mark"], punct), "Really?")
    }

    func testPunctuationOffLeavesTheWord() {
        XCTAssertEqual(stream(["say", "period", "now"], on), "Say period now")
    }

    // MARK: "scratch that": bounded backspace

    func testScratchThatClearsWithNoEarlierBoundary() {
        XCTAssertEqual(streamP([("hello", 0), ("world", 0), ("scratch", 0.5), ("that.", 0), ("again", 0.5)], on),
                       "Again")
    }

    func testScratchThatKeepsThePriorSentence() {
        XCTAssertEqual(streamP([("one", 0), ("period", 0), ("two", 0), ("scratch", 0.5), ("that.", 0),
                                ("three", 0.5)], punct),
                       "One. Three")
    }

    func testScratchThatStopsAtTheBoundary() {
        XCTAssertEqual(streamP([("the", 0), ("engine", 0), ("is", 0), ("fast", 0), ("actually", 0.5),
                                ("scratch", 0.5), ("that.", 0), ("new", 0.5), ("text", 0)], on),
                       "The engine is fast New text")
    }

    func testScratchThatFiresOnTerminatorWithoutTimestampGap() {
        XCTAssertEqual(streamP([("red.", 0), ("scratch", 0), ("that.", 0), ("blue", 0)], on), "Blue")
    }

    func testDeleteThatFileAfterPeriodDoesNotDelete() {
        XCTAssertEqual(streamP([("done.", 0), ("delete", 0), ("that", 0), ("file", 0)], on),
                       "Done. Delete that file")
    }

    func testScratchThatMidSentenceIsLiteral() {
        XCTAssertEqual(stream(["i", "will", "scratch", "that", "itch"], on), "I will scratch that itch")
    }

    // MARK: isolation confirmed by the next word's capital

    func testNewParagraphFiresBeforeACapital() {
        XCTAssertEqual(streamP([("intro.", 0), ("new", 0), ("paragraph", 0), ("Here", 0)], on), "Intro.\n\nHere")
    }

    func testScratchThatFiresBeforeACapital() {
        XCTAssertEqual(streamP([("red.", 0), ("scratch", 0), ("that", 0), ("Blue", 0)], on), "Blue")
    }

    func testScratchThatBeforeLowercaseIsLiteral() {
        XCTAssertEqual(streamP([("done.", 0), ("scratch", 0), ("that", 0), ("plan", 0)], on),
                       "Done. Scratch that plan")
    }

    func testCommandAtEndOfUtteranceFires() {
        XCTAssertEqual(streamP([("wrap", 0), ("up.", 0), ("new", 0), ("line", 0)], on), "Wrap up.\n")
    }

    // MARK: decoder policy

    /// Beam search SIGTRAPs whisper.cpp (exit 133) on some audio, crashing the
    /// app mid-dictation. This fails the instant anyone re-enables it.
    func testShippedDecodingIsGreedy() {
        XCTAssertEqual(Decoding.shipped, .greedy)
    }

    // MARK: stutter collapse

    func testSingleWordStutterIsDropped() {
        XCTAssertEqual(stream(["the", "the", "cat", "sat"], on), "The cat sat")
        XCTAssertEqual(stream(["i", "i", "think", "so"], on), "I think so")
    }

    func testTwoAndThreeWordRestartsAreDropped() {
        XCTAssertEqual(stream(["round", "with", "a", "with", "a", "little", "logo"], on), "Round with a little logo")
        XCTAssertEqual(stream(["it", "is", "a", "it", "is", "a", "cell"], on), "It is a cell")
    }

    func testGrammaticalDoublesSurvive() {
        XCTAssertEqual(stream(["i", "had", "had", "enough"], on), "I had had enough")
        XCTAssertEqual(stream(["i", "know", "that", "that", "works"], on), "I know that that works")
    }

    /// A held word whose repeat breaks is typed, in order, before what follows.
    func testBrokenRepeatKeepsEveryWordInOrder() {
        XCTAssertEqual(stream(["with", "a", "with", "the", "lid"], on), "With a with the lid")
        XCTAssertEqual(stream(["go", "with", "a", "with"], on), "Go with a with")   // flush releases the hold
    }

    /// Words arrive tick by tick; the hold spans feed() calls.
    func testRepeatSpanningTicks() {
        for ticks in 1...5 {
            XCTAssertEqual(stream(["for", "the", "for", "the", "volume"], on, ticks: ticks), "For the volume")
        }
    }

    func testCollapseOffKeepsVerbatim() {
        var c = on; c.collapseRepeats = false
        XCTAssertEqual(stream(["the", "the", "cat"], c), "The the cat")
    }
}
