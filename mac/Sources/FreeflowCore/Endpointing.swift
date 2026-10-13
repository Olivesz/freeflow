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
/// says stop once `silenceMs` of continuous quiet follows the opening grace period.
public struct SilenceEndpointer {
    public let tickMs: Int
    public let graceMs: Int
    public let silenceFloor: Float
    public private(set) var elapsedMs = 0
    public private(set) var silentMs = 0

    public init(tickMs: Int, graceMs: Int, silenceFloor: Float) {
        self.tickMs = tickMs; self.graceMs = graceMs; self.silenceFloor = silenceFloor
    }

    /// One tick. `rms` is the loudness of the last tick, or nil when the window
    /// is still too short to judge. Returns true when the utterance should end.
    public mutating func tick(rms: Float?, silenceMs: Int) -> Bool {
        defer { elapsedMs += tickMs }
        guard let rms else { return false }
        if elapsedMs >= graceMs {
            silentMs = rms < silenceFloor ? silentMs + tickMs : 0
        }
        return silentMs >= silenceMs
    }
}

/// How the decoder searches. MUST stay greedy: beam search SIGTRAPs whisper.cpp
/// (exit 133) on some audio, crashing the app mid-dictation and losing the
/// user's words. A test fails if `shipped` is ever set to beam.
public enum Decoding: String {
    case greedy, beam
    public static let shipped: Decoding = .greedy
}
