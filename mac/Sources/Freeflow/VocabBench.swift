import FluidAudio
import Foundation
import FreeflowCore

/// Hidden mode: `Freeflow --vocab-bench <manifest.json> <glossaries.json> --out <file.json>`.
///
/// Does a custom vocabulary help Parakeet? For each clip with a glossary
/// (`{clip id: [terms]}`), decode with Parakeet, then rescore with FluidAudio's
/// CTC vocabulary boosting using that glossary. Writes the plain and boosted
/// text per clip; the scorer checks rare-word recall, and whether boosting
/// writes glossary terms that weren't said.
enum VocabBench {
    static func run() -> Never {
        SelfTest.spawn {
            let a = CommandLine.arguments
            guard let i = a.firstIndex(of: "--vocab-bench"), i + 2 < a.count,
                  let o = a.firstIndex(of: "--out"), o + 1 < a.count else {
                print("usage: Freeflow --vocab-bench <manifest.json> <glossaries.json> --out <file.json>")
                exit(2)
            }
            try await go(manifest: URL(fileURLWithPath: a[i + 1]), glossaries: URL(fileURLWithPath: a[i + 2]),
                         out: URL(fileURLWithPath: a[o + 1]))
        }
    }

    private static func go(manifest url: URL, glossaries: URL, out: URL) async throws {
        let manifest = try JSONDecoder().decode(Bench.Manifest.self, from: Data(contentsOf: url))
        let lists = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: glossaries))
        let parakeet = try await ParakeetDecoder.load()
        let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        var rows: [[String: String]] = []
        for clip in manifest.clips {
            guard let terms = lists[clip.id] else { continue }
            let frames = try SelfTest.readWav(url.deletingLastPathComponent().appendingPathComponent(clip.path))
            let result = try await parakeet.transcribe(frames)
            let vocab = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            let session = try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc)
            let boosted = await session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [],
                                                audioSamples: frames)
            rows.append(["id": clip.id, "base": result.text, "boosted": boosted?.text ?? result.text])
            if let b = boosted, b.wasModified { print("\(clip.id): \(result.text)\n   → \(b.text)") }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out)
        print("wrote \(rows.count) clips → \(out.path)")
    }
}
