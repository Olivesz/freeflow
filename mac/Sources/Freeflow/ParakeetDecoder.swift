import FluidAudio
import Foundation
import FreeflowCore

/// The speech engines freeflow can run.
enum Engine: String, CaseIterable {
    case parakeet, whisper
    /// What freeflow ships with, and what the benches run by default (never
    /// the user's saved preference, so a result doesn't depend on whose Mac ran it).
    static let shipped: Engine = .parakeet
}

/// NVIDIA Parakeet TDT 0.6B v2 (English) on Core ML via FluidAudio, as the
/// session's `WordDecoder`: each pass decodes one window from scratch, just as
/// whisper.cpp did, so the streamer, endpointer and benches are unchanged.
///
/// Chosen over Whisper on a 125-clip set (meetings, earnings calls, European
/// Parliament, LibriSpeech): about 45% fewer misheard words than base.en, the
/// same as large-v3-turbo but ~3x faster per window, and it doesn't invent
/// text on silence the way Whisper does.
final class ParakeetDecoder: WordDecoder {
    static let version: AsrModelVersion = .v2
    static let name = "parakeet-tdt-0.6b-v2 (Core ML)"
    private static let minSamples = 4800            // FluidAudio's 0.3 s floor

    private let manager: AsrManager

    private init(manager: AsrManager) { self.manager = manager }

    /// Whether the Core ML models are already on disk (else `load` downloads).
    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Downloads the Core ML models on first use (cached under Application
    /// Support/FluidAudio), then loads them onto the Neural Engine.
    static func load() async throws -> ParakeetDecoder {
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetDecoder(manager: manager)
    }

    func words(_ frames: [Float]) async throws -> [Word] {
        let result = try await transcribe(frames)
        return buildWordTimings(from: result.tokenTimings ?? []).map {
            Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }

    /// The full FluidAudio result for one window (text, token timings).
    ///
    /// Decoded at its true length first. If that pass failed (`DecodeCheck`:
    /// blank on audible speech, or a low-confidence loop), decode again padded
    /// with silence to the model's full 15 s input, which sidesteps the length
    /// bug and decoded every failing window tried; keep the more confident of
    /// the two. Padding every window instead would cost accuracy on all of
    /// them (offline WER 1.4% -> 2.0% on the benchmark clips).
    func transcribe(_ frames: [Float]) async throws -> ASRResult {
        let first = try await decode(frames, padTo: Self.minSamples)
        guard DecodeCheck.failed(confidences: Self.confidences(first), audio: frames) else { return first }
        let retry = try await decode(frames, padTo: ASRConstants.maxModelSamples)
        return Self.mean(Self.confidences(retry)) > Self.mean(Self.confidences(first)) ? retry : first
    }

    private func decode(_ frames: [Float], padTo length: Int) async throws -> ASRResult {
        let audio = frames + [Float](repeating: 0, count: max(0, length - frames.count))
        var state = try TdtDecoderState(decoderLayers: 2)   // windows decode independently
        return try await manager.transcribe(audio, decoderState: &state)
    }

    private static func confidences(_ r: ASRResult) -> [Float] { (r.tokenTimings ?? []).map(\.confidence) }
    private static func mean(_ c: [Float]) -> Float { c.isEmpty ? 0 : c.reduce(0, +) / Float(c.count) }
}
