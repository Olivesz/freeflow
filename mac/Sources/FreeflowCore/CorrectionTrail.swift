import Foundation

/// What became of dictated text after it was typed: the user's own corrections,
/// read back from the text field a while later. That is a label for every
/// error that mattered, at no cost to the user.
///
/// Everything here is in UTF-16 code units, the units Accessibility reports
/// text ranges in.
public enum CorrectionTrail {
    public struct Followed: Equatable {
        public let text: String        // what the dictated span reads as now
        public let distance: Int       // edit distance from what was typed
        public let anchored: Bool      // found by the text just before it
    }

    /// Where `typed` sits in `field` right after it was typed: ending at the
    /// caret when it does, else its last occurrence.
    public static func locate(_ typed: String, in field: String, caret: Int?) -> Range<Int>? {
        let t = Array(typed.utf16), f = Array(field.utf16)
        guard !t.isEmpty, t.count <= f.count else { return nil }
        if let c = caret, c >= t.count, c <= f.count, Array(f[(c - t.count)..<c]) == t {
            return (c - t.count)..<c
        }
        var i = f.count - t.count
        while i >= 0 {
            if f[i] == t[0], Array(f[i..<(i + t.count)]) == t { return i..<(i + t.count) }
            i -= 1
        }
        return nil
    }

    /// What the span of `before` at `span` became in `after`.
    ///
    /// Found by the text just before it (`context` units), when that survived,
    /// then by aligning what was typed against what follows the anchor with a
    /// free end: text the user kept typing after the dictation is not counted
    /// as a correction. Without the anchor the whole field is searched. Nil
    /// when nothing in `after` is closer to the typed text than half its length,
    /// for instance when the message was sent and the field cleared.
    public static func follow(span: Range<Int>, before: String, after: String,
                              context: Int = 32) -> Followed? {
        let b = Array(before.utf16), a = Array(after.utf16)
        guard span.lowerBound >= 0, span.upperBound <= b.count, !span.isEmpty else { return nil }
        let typed = Array(b[span])
        let left = Array(b[max(0, span.lowerBound - context)..<span.lowerBound])

        var start: Int? = nil
        if left.isEmpty {
            start = 0
        } else if let at = nearestOccurrence(of: left, in: a, near: span.lowerBound - left.count) {
            start = at + left.count
        }
        let best: (lo: Int, hi: Int, d: Int)
        if let s = start {
            let end = min(a.count, s + typed.count * 2 + 64)
            let m = align(typed, Array(a[s..<end]), freeStart: false)
            best = (s + m.lo, s + m.hi, m.d)
        } else {
            let lo = max(0, span.lowerBound - 10_000), hi = min(a.count, span.upperBound + 10_000)
            let m = align(typed, Array(a[lo..<hi]), freeStart: true)
            best = (lo + m.lo, lo + m.hi, m.d)
        }
        guard best.d <= max(4, typed.count / 2) else { return nil }
        return Followed(text: String(decoding: a[best.lo..<best.hi], as: UTF16.self),
                        distance: best.d, anchored: start != nil)
    }

    private static func nearestOccurrence(of p: [UInt16], in a: [UInt16], near: Int) -> Int? {
        guard !p.isEmpty, p.count <= a.count else { return nil }
        var best: Int?
        for i in 0...(a.count - p.count) where a[i] == p[0] && Array(a[i..<(i + p.count)]) == p {
            if best == nil || abs(i - near) < abs(best! - near) { best = i }
        }
        return best
    }

    /// Edit distance of `t` against a substring of `a` that starts at 0 (or
    /// anywhere, with `freeStart`) and ends anywhere. On ties the match closest
    /// in length to `t` wins ("Friday!" over "Friday" for "Friday."), then the
    /// shorter, so trailing text is left out.
    static func align(_ t: [UInt16], _ a: [UInt16], freeStart: Bool) -> (lo: Int, hi: Int, d: Int) {
        let n = t.count, m = a.count
        // dp[j] = distance aligning t[0..<i] to a substring ending at j; from[j] = its start.
        var prev = [Int](repeating: 0, count: m + 1), from = Array(0...m)
        if !freeStart { for j in 0...m { prev[j] = j }; from = [Int](repeating: 0, count: m + 1) }
        var cur = prev, curFrom = from
        for i in 1...max(n, 1) where n > 0 {
            cur[0] = i; curFrom[0] = 0
            for j in 1...max(m, 1) where m > 0 {
                let sub = prev[j - 1] + (t[i - 1] == a[j - 1] ? 0 : 1)
                let del = prev[j] + 1          // typed char missing from the field
                let ins = cur[j - 1] + 1       // field char not in what was typed
                if sub <= del && sub <= ins { cur[j] = sub; curFrom[j] = from[j - 1] }
                else if del <= ins { cur[j] = del; curFrom[j] = from[j] }
                else { cur[j] = ins; curFrom[j] = curFrom[j - 1] }
            }
            swap(&prev, &cur); swap(&from, &curFrom)
        }
        var bestJ = 0
        for j in 0...m {
            let gap = abs(j - from[j] - n), bestGap = abs(bestJ - from[bestJ] - n)
            if prev[j] < prev[bestJ] || (prev[j] == prev[bestJ] && gap < bestGap) { bestJ = j }
        }
        return (from[bestJ], bestJ, prev[bestJ])
    }
}
