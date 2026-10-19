import AVFoundation
import FreeflowCore

/// Captures the mic and resamples to the 16 kHz mono float that whisper.cpp
/// wants. The audio thread just appends into a locked buffer; the transcription
/// loop takes `snapshot()`s of it.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        lock.lock(); samples.removeAll(); lock.unlock()
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// RMS over an absolute time interval of the utterance — for diagnosing
    /// whether a transcript gap coincided with real speech energy.
    func rms(fromSec: Double, toSec: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        let a = max(0, Int(fromSec * 16000)), b = min(samples.count, Int(toSec * 16000))
        guard b > a else { return 0 }
        let slice = samples[a..<b]
        let sum = slice.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(b - a)).squareRoot()
    }

    /// RMS of the quietest 50 ms frame in the last `ms` — the room reference.
    func recentQuietestRMS(ms: Int) -> Float {
        lock.lock(); defer { lock.unlock() }
        let n = min(samples.count, 16000 * ms / 1000)
        return Audio.quietestFrameRMS(samples.suffix(n))
    }

    /// RMS of the last `ms` of captured audio — the VAD's raw signal.
    func recentRMS(ms: Int) -> Float {
        lock.lock(); defer { lock.unlock() }
        let n = min(samples.count, 16000 * ms / 1000)
        guard n > 0 else { return 0 }
        let slice = samples.suffix(n)
        let sum = slice.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(n)).squareRoot()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let frames = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: frames); lock.unlock()
    }
}
