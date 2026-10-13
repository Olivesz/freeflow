import Foundation

/// Word error rate and the small statistics the benchmark reports.
public enum Scoring {
    /// Lowercase words with punctuation stripped, so "Americans," matches the
    /// reference "AMERICANS". Hyphens split words; apostrophes stay ("don't").
    /// Numbers are not spelled out: a digit against a spelled reference counts
    /// as an error, the same way for the streamed and the offline transcript.
    public static func normalize(_ s: String) -> [String] {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "-", with: " ")
        let kept = lowered.unicodeScalars.map { c -> Character in
            CharacterSet.alphanumerics.contains(c) || c == "'" ? Character(c) : " "
        }
        return String(kept).split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    public struct Alignment: Equatable {
        public let reference: Int
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int

        public init(reference: Int, substitutions: Int, deletions: Int, insertions: Int) {
            self.reference = reference; self.substitutions = substitutions
            self.deletions = deletions; self.insertions = insertions
        }

        public var errors: Int { substitutions + deletions + insertions }
        public var wer: Double { reference == 0 ? 0 : Double(errors) / Double(reference) }
    }

    /// Minimum edit distance between word sequences, split into S/D/I. Ties
    /// prefer a substitution, then a deletion, so the split is deterministic.
    public static func align(reference ref: [String], hypothesis hyp: [String]) -> Alignment {
        let n = ref.count, m = hyp.count
        // cost[i][j] = (edits, subs, dels, ins) for ref[..<i] vs hyp[..<j]
        var cost = Array(repeating: Array(repeating: (0, 0, 0, 0), count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = (i, 0, i, 0) }
        for j in 0...m { cost[0][j] = (j, 0, 0, j) }
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                if ref[i - 1] == hyp[j - 1] { cost[i][j] = cost[i - 1][j - 1]; continue }
                let s = cost[i - 1][j - 1], d = cost[i - 1][j], a = cost[i][j - 1]
                let best = min(s.0, d.0, a.0)
                if s.0 == best { cost[i][j] = (s.0 + 1, s.1 + 1, s.2, s.3) }
                else if d.0 == best { cost[i][j] = (d.0 + 1, d.1, d.2 + 1, d.3) }
                else { cost[i][j] = (a.0 + 1, a.1, a.2, a.3 + 1) }
            }
        }
        let c = cost[n][m]
        return Alignment(reference: n, substitutions: c.1, deletions: c.2, insertions: c.3)
    }

    /// Nearest-rank percentile (p in 0...100); nil for an empty sample.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
