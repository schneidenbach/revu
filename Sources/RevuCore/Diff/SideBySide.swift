import Foundation

/// One rendered cell (one side of a row, or one line in the file view).
public struct SideCell: Sendable, Equatable {
    public enum Kind: Sendable { case context, added, removed, filler }
    public let kind: Kind
    /// Line number in the old file (left cells) or new file (right cells).
    public let number: Int?
    /// Display text: tabs expanded.
    public let text: String
    /// UTF-16 ranges of `text` that changed within a paired line.
    public let changedRanges: [Range<Int>]
    /// Index into `FileDiff.lines`.
    public let diffIndex: Int?

    static let filler = SideCell(kind: .filler, number: nil, text: "", changedRanges: [], diffIndex: nil)
}

public struct SideBySideRow: Identifiable, Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case pair(left: SideCell, right: SideCell)
        /// `runStart` identifies the run of unchanged lines (index into `FileDiff.lines`) for expansion.
        case collapsed(hidden: Int, runStart: Int)
    }
    /// Stable across expand/collapse: the diff-line index of the first line shown, or a negative id for separators.
    public let id: Int
    public let content: Content

    public var isChange: Bool {
        guard case let .pair(l, r) = content else { return false }
        return l.kind == .removed || r.kind == .added
    }
}

public enum DisplayText {
    /// Expands tabs to the next multiple of `width` columns.
    public static func expandTabs(_ s: String, width: Int = 4) -> String {
        guard s.utf8.contains(9) else { return s }
        var out = ""
        var column = 0
        for ch in s {
            if ch == "\t" {
                let n = width - column % width
                out += String(repeating: " ", count: n)
                column += n
            } else {
                out.append(ch)
                column += 1
            }
        }
        return out
    }
}

public enum SideBySide {
    public static let collapseThreshold = 8
    public static let contextLines = 3

    /// - Parameters:
    ///   - expandedRuns: starts of unchanged runs the user expanded.
    ///   - expandAll: show everything.
    ///   - pinned: diff-line indexes (e.g. lines with comments) that must stay visible with context around them.
    public static func build(
        diff: FileDiff, expandedRuns: Set<Int> = [], expandAll: Bool = false, pinned: Set<Int> = []
    ) -> [SideBySideRow] {
        let lines = diff.lines
        let hasChange = lines.contains { $0.kind != .context }
        var rows: [SideBySideRow] = []
        rows.reserveCapacity(lines.count)

        func contextRow(_ i: Int) -> SideBySideRow {
            let line = lines[i]
            let text = DisplayText.expandTabs(line.text)
            return SideBySideRow(id: i, content: .pair(
                left: SideCell(kind: .context, number: line.oldLine, text: text, changedRanges: [], diffIndex: i),
                right: SideCell(kind: .context, number: line.newLine, text: text, changedRanges: [], diffIndex: i)))
        }

        var i = 0
        while i < lines.count {
            var j = i
            if lines[i].kind == .context {
                while j < lines.count, lines[j].kind == .context { j += 1 }
                let collapsible = hasChange && !expandAll && !expandedRuns.contains(i) && j - i > collapseThreshold
                if collapsible {
                    appendCollapsed(run: i..<j, total: lines.count, pinned: pinned, rows: &rows, contextRow: contextRow)
                } else {
                    for k in i..<j { rows.append(contextRow(k)) }
                }
            } else {
                while j < lines.count, lines[j].kind != .context { j += 1 }
                appendChangeBlock(i..<j, lines: lines, rows: &rows)
            }
            i = j
        }
        return rows
    }

    private static func appendCollapsed(
        run: Range<Int>, total: Int, pinned: Set<Int>, rows: inout [SideBySideRow], contextRow: (Int) -> SideBySideRow
    ) {
        var visible = Set<Int>()
        if run.lowerBound > 0 { visible.formUnion(run.lowerBound..<min(run.lowerBound + contextLines, run.upperBound)) }
        if run.upperBound < total { visible.formUnion(max(run.upperBound - contextLines, run.lowerBound)..<run.upperBound) }
        for p in pinned where p >= run.lowerBound - contextLines && p < run.upperBound + contextLines {
            let r = max(p - contextLines, run.lowerBound)...min(p + contextLines, run.upperBound - 1)
            visible.formUnion(r)
        }

        var k = run.lowerBound
        while k < run.upperBound {
            if visible.contains(k) {
                rows.append(contextRow(k))
                k += 1
            } else {
                var end = k
                while end < run.upperBound, !visible.contains(end) { end += 1 }
                rows.append(SideBySideRow(id: -(k + 1), content: .collapsed(hidden: end - k, runStart: run.lowerBound)))
                k = end
            }
        }
    }

    private static func appendChangeBlock(_ block: Range<Int>, lines: [DiffLine], rows: inout [SideBySideRow]) {
        let removed = block.filter { lines[$0].kind == .removed }
        let added = block.filter { lines[$0].kind == .added }
        for t in 0..<max(removed.count, added.count) {
            let r = t < removed.count ? removed[t] : nil
            let a = t < added.count ? added[t] : nil
            let rText = r.map { DisplayText.expandTabs(lines[$0].text) }
            let aText = a.map { DisplayText.expandTabs(lines[$0].text) }

            var rRanges: [Range<Int>] = [], aRanges: [Range<Int>] = []
            if let rText, let aText { (rRanges, aRanges) = WordDiff.changedRanges(old: rText, new: aText) }

            let left = r.map { SideCell(kind: .removed, number: lines[$0].oldLine, text: rText!, changedRanges: rRanges, diffIndex: $0) } ?? .filler
            let right = a.map { SideCell(kind: .added, number: lines[$0].newLine, text: aText!, changedRanges: aRanges, diffIndex: $0) } ?? .filler
            rows.append(SideBySideRow(id: r ?? a!, content: .pair(left: left, right: right)))
        }
    }
}
