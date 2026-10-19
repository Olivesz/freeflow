import Foundation

/// The audio-side rules around the decoder: what is too quiet to transcribe,
/// where the voiced tail of a window ends, and when silence ends an utterance.
public enum Audio {
    public static let sampleRate = 16000

    public static func rms(_ frames: ArraySlice<Float>) -> Float {
        guard !frames.isEmpty else { return 0 }
        let sum = frames.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(frames.count)).squareRoot()
    }

    public static func rms(_ frames: [Float]) -> Float { rms(frames[...]) }

    /// RMS of the quietest 50 ms frame — the gaps between syllables, which hear
    /// the room even while someone is talking.
    public static func quietestFrameRMS(_ frames: ArraySlice<Float>) -> Float {
        let frame = 800
        var lo = Float.greatestFiniteMagnitude, i = frames.startIndex
        while i + frame <= frames.endIndex {
            lo = min(lo, rms(frames[i..<i + frame])); i += frame
        }
        return lo == .greatestFiniteMagnitude ? rms(frames) : lo
    }

    /// Cut trailing quiet off the window so Whisper never transcribes silence
    /// (which it "fills in" with hallucinated phrases like "thank you"). Scans
    /// back in 50ms frames to the last voiced one and keeps ~0.2s of padding.
    public static func trimTrailingSilence(_ frames: [Float]) -> [Float] {
        let frame = 800                                   // 50 ms @ 16 kHz
        let floor: Float = 0.010
        var i = frames.count - frame
        while i > 0 {
            if rms(frames[i..<min(i + frame, frames.count)]) > floor {
                let end = min(frames.count, i + frame + 3200)   // keep +0.2 s
                return end < frames.count ? Array(frames[0..<end]) : frames
            }
            i -= frame
        }
        return frames   // no clear voiced tail found — leave it, other guards apply
    }
}

/// Voice-activity auto-stop. Fed once per tick with the loudness of that tick;
/// says stop once enough continuous quiet follows the opening grace period.
///
/// What counts as speech: anything at or above the old fixed `legacyFloor`
/// (so this can never call something silence that the shipped rule called
/// speech), OR anything clearly above the room — the noise floor is the
/// quietest tick of the last ~4 s, and the gate has hysteresis (4x the floor
/// to open, 2x to stay open). The second rule rescues quiet speakers and
/// laptop mics that the fixed threshold heard as silence.
///
/// How much quiet is enough depends on the sentence: while the transcript so
/// far ends mid-sentence ("…the second option is better. Because") the speaker is
/// thinking, not done, so the stop waits `openSentenceFactor`× longer. Real
/// dictations were being cut off right after words like "because", "when",
/// and mid-word fragments ending in "-".
public struct SilenceEndpointer {
    public static let openSentenceFactor = 3
    public static let legacyFloor: Float = 0.006
    static let floorWindowTicks = 12            // ~4.2 s at the 350 ms tick

    public let tickMs: Int
    public let graceMs: Int
    /// No tick quieter than this counts as speech by the adaptive rule, so a
    /// dead-silent room doesn't make the gate hair-trigger.
    public let minSpeech: Float
    /// Both default on; off reproduces the endpointer that shipped before
    /// them (fixed 0.006 floor, one timeout), for the --pause-bench comparison.
    public let adaptive: Bool
    public let holdOpenSentences: Bool
    public private(set) var elapsedMs = 0
    public private(set) var silentMs = 0
    public private(set) var speaking = false
    private var recent: [Float] = []

    /// Quietest tick of the last ~4 s: the room, not the speech.
    public var noiseFloor: Float { max(recent.min() ?? Self.legacyFloor, 1e-4) }

    public init(tickMs: Int, graceMs: Int, minSpeech: Float = 0.004,
                adaptive: Bool = true, holdOpenSentences: Bool = true) {
        self.tickMs = tickMs; self.graceMs = graceMs; self.minSpeech = minSpeech
        self.adaptive = adaptive; self.holdOpenSentences = holdOpenSentences
    }

    /// One tick. `rms` is the loudness of the last tick, or nil when the window
    /// is still too short to judge; `quietest` is its quietest 50 ms frame (the
    /// room reference — defaults to `rms`). `sentenceOpen` is true when the
    /// latest transcript doesn't end a sentence. Returns true when the
    /// utterance should end.
    public mutating func tick(rms: Float?, quietest: Float? = nil, silenceMs: Int,
                              sentenceOpen: Bool = false) -> Bool {
        defer { elapsedMs += tickMs }
        guard let rms else { return false }
        let voiced = isSpeech(rms, quietest: quietest)
        if elapsedMs >= graceMs {
            silentMs = voiced ? 0 : silentMs + tickMs
        }
        let hold = holdOpenSentences && sentenceOpen
        return silentMs >= (hold ? silenceMs * Self.openSentenceFactor : silenceMs)
    }

    /// Speech gate: the legacy fixed floor, or clearly above the room (with
    /// hysteresis). Updates the noise-floor window.
    public mutating func isSpeech(_ rms: Float, quietest: Float? = nil) -> Bool {
        recent.append(min(quietest ?? rms, rms))
        if recent.count > Self.floorWindowTicks { recent.removeFirst() }
        let k: Float = speaking ? 2 : 4
        speaking = rms >= Self.legacyFloor || (adaptive && rms > max(noiseFloor * k, minSpeech))
        return speaking
    }
}

extension Word {
    /// True when this word closes a sentence: Whisper ends it with . ? or !
    public var endsSentence: Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!".contains(last)
    }

    /// True when a sentence can't end on this word: a function word that needs
    /// what follows ("because", "and", "the", "when", "than", "is"…) or a cut-off
    /// fragment ("inter-"). Judged on the word, not its punctuation: Whisper
    /// puts a period on the last word of whatever audio it is given, so a pause
    /// after "wizard," decodes as "wizard." and its period proves nothing.
    public var continuesSentence: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("-") { return true }
        let w = t.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return Self.continuationWords.contains(w)
    }

    static let continuationWords: Set<String> = [
        // conjunctions and clause openers
        "and", "but", "or", "nor", "so", "yet", "because", "since", "although", "though", "while",
        "whereas", "unless", "until", "if", "when", "whenever", "where", "whether", "than", "as",
        "that", "which", "who", "whom", "whose",
        // articles, determiners, possessives
        "a", "an", "the", "this", "these", "those", "my", "your", "our", "their", "his", "its",
        "some", "any", "every", "each",
        // prepositions
        "of", "to", "in", "on", "at", "by", "for", "with", "from", "into", "onto", "about",
        "between", "through", "during", "against", "among", "without", "within", "via", "per",
        // auxiliaries and copulas that need a complement
        "is", "are", "was", "were", "be", "been", "being", "am", "will", "would", "can", "could",
        "should", "shall", "may", "might", "must", "do", "does", "did", "have", "has", "had",
        // subject pronouns, intensifiers, fillers
        "i", "we", "they", "he", "she", "very", "quite", "rather", "um", "uh", "like",
    ]
}

/// How the decoder searches. MUST stay greedy: beam search SIGTRAPs whisper.cpp
/// (exit 133) on some audio, crashing the app mid-dictation and losing the
/// user's words. A test fails if `shipped` is ever set to beam.
public enum Decoding: String {
    case greedy, beam
    public static let shipped: Decoding = .greedy
}

/// When a decoder pass failed rather than heard nothing. FluidAudio's Core ML
/// Parakeet v2 sometimes returns no tokens for clear speech, or a low-confidence
/// loop ("The case of the case of the city of the"), depending on the window's
/// length (FluidAudio #909; its own retry covers v3 only). Measured on failing
/// windows: real decodes have mean token confidence 0.78-1.00, the garbage
/// ones 0.14-0.16. A pass that fails this check is retried another way.
public enum DecodeCheck {
    public static let minConfidence: Float = 0.4

    /// `confidences` are the pass's per-token confidences.
    public static func failed(confidences: [Float], audio: [Float]) -> Bool {
        if confidences.isEmpty {                       // blank: wrong only if there was speech
            return audio.count >= 8000 && Audio.rms(audio) >= 0.003
        }
        return confidences.reduce(0, +) / Float(confidences.count) < minConfidence
    }
}
