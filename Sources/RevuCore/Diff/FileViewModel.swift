import Foundation

/// Removed lines shown (on demand) between two lines of the new file.
public struct RemovedBlock: Sendable, Equatable {
    public let lines: [SideCell]
}

public struct FileViewLine: Identifiable, Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case line(SideCell)
        case removed(RemovedBlock)
    }
    /// Diff-line index for lines; `-(firstRemovedIndex + 1)` for removed blocks.
    public let id: Int
    public let content: Content
}

public enum FileViewModel {
    /// The new version of the file with a marker wherever lines were removed. For a deleted file the
    /// old content is returned as removed lines.
    public static func build(diff: FileDiff) -> [FileViewLine] {
        let lines = diff.lines
        var out: [FileViewLine] = []
        out.reserveCapacity(lines.count)

        if diff.isDeleted {
            for (i, line) in lines.enumerated() {
                out.append(FileViewLine(id: i, content: .line(
                    SideCell(kind: .removed, number: line.oldLine, text: DisplayText.expandTabs(line.text), changedRanges: [], diffIndex: i))))
            }
            return out
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.kind == .context {
                out.append(FileViewLine(id: i, content: .line(
                    SideCell(kind: .context, number: line.newLine, text: DisplayText.expandTabs(line.text), changedRanges: [], diffIndex: i))))
                i += 1
                continue
            }
            var j = i
            while j < lines.count, lines[j].kind != .context { j += 1 }
            let removed = (i..<j).filter { lines[$0].kind == .removed }
            let added = (i..<j).filter { lines[$0].kind == .added }

            if let first = removed.first {
                let cells = removed.map {
                    SideCell(kind: .removed, number: lines[$0].oldLine, text: DisplayText.expandTabs(lines[$0].text), changedRanges: [], diffIndex: $0)
                }
                out.append(FileViewLine(id: -(first + 1), content: .removed(RemovedBlock(lines: cells))))
            }
            for (t, index) in added.enumerated() {
                let text = DisplayText.expandTabs(lines[index].text)
                var ranges: [Range<Int>] = []
                if t < removed.count {
                    ranges = WordDiff.changedRanges(old: DisplayText.expandTabs(lines[removed[t]].text), new: text).new
                }
                out.append(FileViewLine(id: index, content: .line(
                    SideCell(kind: .added, number: lines[index].newLine, text: text, changedRanges: ranges, diffIndex: index))))
            }
            i = j
        }
        return out
    }
}
