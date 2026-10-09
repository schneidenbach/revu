import Foundation

/// Intra-line change detection. Ranges are in UTF-16 offsets so they can be used with NSRange /
/// AttributedString directly.
public enum WordDiff {
    public typealias Ranges = (old: [Range<Int>], new: [Range<Int>])

    public static let maxLineLength = 1_000
    /// Upper bound on the LCS table size (tokens × tokens) before falling back to prefix/suffix trimming only.
    static let maxTableCells = 250_000

    public static func changedRanges(old: String, new: String, maxLength: Int = maxLineLength) -> Ranges {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard old != new, a.count <= maxLength, b.count <= maxLength else { return ([], []) }

        let ta = tokenize(a), tb = tokenize(b)
        var changedA = [Bool](repeating: true, count: ta.count)
        var changedB = [Bool](repeating: true, count: tb.count)

        // Trim common prefix/suffix tokens, then LCS on the middle.
        var prefix = 0
        while prefix < ta.count, prefix < tb.count, same(ta[prefix], tb[prefix], a, b) { prefix += 1 }
        var suffix = 0
        while suffix < ta.count - prefix, suffix < tb.count - prefix,
              same(ta[ta.count - 1 - suffix], tb[tb.count - 1 - suffix], a, b) { suffix += 1 }

        var sharedNonSpace = false
        func markShared(_ i: Int, _ j: Int) {
            changedA[i] = false
            changedB[j] = false
            if !isSpace(a[ta[i].lowerBound]) { sharedNonSpace = true }
        }
        for k in 0..<prefix { markShared(k, k) }
        for k in 0..<suffix { markShared(ta.count - 1 - k, tb.count - 1 - k) }

        let midA = prefix..<(ta.count - suffix), midB = prefix..<(tb.count - suffix)
        if !midA.isEmpty, !midB.isEmpty, midA.count * midB.count <= maxTableCells {
            let n = midA.count, m = midB.count
            var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
            let w = m + 1
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * w + j] = same(ta[midA.lowerBound + i], tb[midB.lowerBound + j], a, b)
                        ? table[(i + 1) * w + j + 1] + 1
                        : max(table[(i + 1) * w + j], table[i * w + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if same(ta[midA.lowerBound + i], tb[midB.lowerBound + j], a, b) {
                    markShared(midA.lowerBound + i, midB.lowerBound + j)
                    i += 1; j += 1
                } else if table[(i + 1) * w + j] >= table[i * w + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        // Nothing meaningful in common: the line-level background already says "whole line changed".
        guard sharedNonSpace else { return ([], []) }
        return (merge(ta, changedA), merge(tb, changedB))
    }

    // MARK: Tokens

    private static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }
    private static func isWord(_ u: UInt16) -> Bool {
        (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u >= 0x80
    }

    /// Words, whitespace runs, and single punctuation characters.
    private static func tokenize(_ s: [UInt16]) -> [Range<Int>] {
        var tokens: [Range<Int>] = []
        var i = 0
        while i < s.count {
            var j = i + 1
            if isWord(s[i]) { while j < s.count, isWord(s[j]) { j += 1 } }
            else if isSpace(s[i]) { while j < s.count, isSpace(s[j]) { j += 1 } }
            tokens.append(i..<j)
            i = j
        }
        return tokens
    }

    private static func same(_ x: Range<Int>, _ y: Range<Int>, _ a: [UInt16], _ b: [UInt16]) -> Bool {
        x.count == y.count && a[x] .elementsEqual(b[y])
    }

    private static func merge(_ tokens: [Range<Int>], _ changed: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (t, isChanged) in zip(tokens, changed) where isChanged {
            if let last = out.last, last.upperBound == t.lowerBound {
                out[out.count - 1] = last.lowerBound..<t.upperBound
            } else {
                out.append(t)
            }
        }
        return out
    }
}
