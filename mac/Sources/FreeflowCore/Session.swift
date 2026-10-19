import Foundation

/// Anything that turns a window of 16 kHz mono audio into timestamped words,
/// times relative to the window start. The app wraps whisper.cpp; tests script it.
public protocol WordDecoder {
    func words(_ frames: [Float]) async throws -> [Word]
}

/// One decoder pass, as the streamer saw it.
public struct Pass {
    public let audioEnd: Double        // seconds of audio captured when the pass ran
    public let windowStart: Double     // seconds trimmed off the front at the time
    public let hypothesis: [Word]      // decoder output, absolute times
    public let committed: [Word]       // words this pass made stable
    public let decodeMs: Double
    public let final: Bool
}

/// The per-tick rules of a dictation, shared by the app's live loop and the
/// offline replays (--selftest, --bench), so what gets measured is what ships:
/// skip windows under 0.5 s, cut the trailing silence, skip dead-silent
/// windows, decode, then let the streamer decide what is stable.
public final class StreamingSession {
    public static let minWindowSamples = 8000      // 0.5 s
    public static let silenceFloor: Float = 0.006

    public let streamer: WhisperStreamer
    public private(set) var passes: [Pass] = []

    public init(config: WhisperStreamer.Config = .shipped) {
        streamer = WhisperStreamer(config: config)
    }

    public func reset() { streamer.reset(); passes = [] }

    /// True when the latest decoder pass ends mid-sentence: its last real word
    /// can't end one ("because", "the", "inter-") or ends in a comma, colon or
    /// semicolon. The endpointer waits longer then: the speaker is mid-thought.
    /// False before anything has been heard.
    ///
    /// A missing period is not a signal: the window's trailing silence is cut
    /// before decoding, so Parakeet hears speech stop dead and leaves the last
    /// word of a finished sentence bare ("…inward joy"), every tick.
    public var sentenceOpen: Bool {
        guard let last = passes.last?.hypothesis.last(where: {
            $0.text.rangeOfCharacter(from: .letters) != nil
        }) else { return false }
        return last.continuesSentence || last.endsClause
    }

    /// One live tick over everything captured so far. Returns newly-stable words.
    public func tick(audio full: [Float], decoder: WordDecoder) async throws -> [Word] {
        let startS = streamer.windowStartSample()
        guard full.count - startS >= Self.minWindowSamples else { return [] }
        let window = Audio.trimTrailingSilence(Array(full[startS...]))
        guard Audio.rms(window) >= Self.silenceFloor else { return [] }
        return try await run(window, audioEnd: full.count, final: false, decoder: decoder)
    }

    /// Stop: one last pass over the tail, trusting whatever it hears.
    public func finish(audio full: [Float], decoder: WordDecoder) async throws -> [Word] {
        let startS = streamer.windowStartSample()
        let tail = Audio.trimTrailingSilence(Array(full[min(max(0, startS), full.count)...]))
        guard tail.count > 800 else { return [] }
        return try await run(tail, audioEnd: full.count, final: true, decoder: decoder)
    }

    private func run(_ window: [Float], audioEnd: Int, final: Bool,
                     decoder: WordDecoder) async throws -> [Word] {
        let offset = streamer.offset
        let t0 = Date()
        let words = try await decoder.words(window)
        let ms = Date().timeIntervalSince(t0) * 1000
        let seconds = Double(window.count) / Double(Audio.sampleRate)
        let committed = final ? streamer.finalize(window: words, duration: seconds)
                              : streamer.process(window: words, duration: seconds)
        passes.append(Pass(
            audioEnd: Double(audioEnd) / Double(Audio.sampleRate), windowStart: offset,
            hypothesis: words.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset) },
            committed: committed, decodeMs: ms, final: final))
        return committed
    }
}
