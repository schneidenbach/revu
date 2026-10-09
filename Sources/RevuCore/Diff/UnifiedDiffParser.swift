import Foundation

public enum DiffLineKind: Sendable, Equatable {
    case context, added, removed
}

public enum Side: String, Codable, Sendable {
    case new, old
}

public struct DiffLine: Sendable, Equatable {
    public let kind: DiffLineKind
    public let oldLine: Int?
    public let newLine: Int?
    /// Content without the diff prefix and without a trailing CR.
    public let text: String
    /// True when git reported `\ No newline at end of file` for this line.
    public let missingNewline: Bool

    public init(kind: DiffLineKind, oldLine: Int?, newLine: Int?, text: String, missingNewline: Bool = false) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
        self.missingNewline = missingNewline
    }
}

public struct FileDiff: Sendable, Equatable {
    public var path: String
    public var oldPath: String?
    public var isNew = false
    public var isDeleted = false
    public var isRename = false
    public var isBinary = false
    public var oldMode: String?
    public var newMode: String?
    public var similarity: Int?
    public private(set) var lines: [DiffLine]
    /// Indexes into `lines` where each hunk begins.
    public private(set) var hunkStarts: [Int]
    private var newIndex: [Int] = []
    private var oldIndex: [Int] = []

    public init(path: String, oldPath: String? = nil, lines: [DiffLine] = [], hunkStarts: [Int] = []) {
        self.path = path
        self.oldPath = oldPath
        self.lines = lines
        self.hunkStarts = hunkStarts
        reindex()
    }

    mutating func setLines(_ lines: [DiffLine], hunkStarts: [Int]) {
        self.lines = lines
        self.hunkStarts = hunkStarts
        reindex()
    }

    private mutating func reindex() {
        newIndex = lines.indices.filter { lines[$0].newLine != nil }
        oldIndex = lines.indices.filter { lines[$0].oldLine != nil }
    }

    /// Index into `lines` of the given 1-based line on `side`.
    public func lineIndex(side: Side, number: Int) -> Int? {
        let index = side == .new ? newIndex : oldIndex
        var lo = 0, hi = index.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let line = lines[index[mid]]
            let n = (side == .new ? line.newLine : line.oldLine) ?? 0
            if n == number { return index[mid] }
            if n < number { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// Where a comment on `line` of `side` should be anchored. An old-side line that is unchanged
    /// context was never removed, so it is anchored on the new side (at its new line number), which
    /// is also where the File view and the rendered output expect it.
    public func canonicalAnchor(side: Side, line: Int) -> (side: Side, line: Int) {
        if side == .old, let i = lineIndex(side: .old, number: line),
           lines[i].kind == .context, let new = lines[i].newLine {
            return (.new, new)
        }
        return (side, line)
    }

    /// The line of the working-tree file to open in an editor for the diff line at `index`: its new line
    /// number, or for a removed line the new line number of the next line that survives (where the
    /// removal happened), or the last line of the file when the removal was at the end. Nil when the file
    /// has no new lines at all (it was deleted).
    public func editorLine(forDiffIndex index: Int) -> Int? {
        guard lines.indices.contains(index) else { return nil }
        if let new = lines[index].newLine { return new }
        for later in lines[(index + 1)...] { if let new = later.newLine { return new } }
        return lines[..<index].last { $0.newLine != nil }?.newLine
    }

    /// Same, addressed by side and line number (as comments and cells are).
    public func editorLine(side: Side, number: Int) -> Int? {
        lineIndex(side: side, number: number).flatMap(editorLine(forDiffIndex:))
    }

    /// Text of lines `start...end` on `side`, joined with `\n`; nil if any line is missing.
    public func text(side: Side, from start: Int, to end: Int) -> String? {
        guard start <= end else { return nil }
        var parts: [String] = []
        for n in start...end {
            guard let i = lineIndex(side: side, number: n) else { return nil }
            parts.append(lines[i].text)
        }
        return parts.joined(separator: "\n")
    }
}

public enum UnifiedDiffParser {
    public static func parse(_ text: String, path: String, oldPath: String? = nil) -> FileDiff {
        parse(Data(text.utf8), path: path, oldPath: oldPath)
    }

    /// Parses the output of `git diff` for a single file. Paths come from the caller (never from
    /// `diff --git` headers, which are ambiguous for names with spaces). Splits on raw bytes so that
    /// CRLF content is not merged into one grapheme by Swift's String.
    public static func parse(_ data: Data, path: String, oldPath: String? = nil) -> FileDiff {
        var diff = FileDiff(path: path, oldPath: oldPath)
        var rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }

        func string(_ slice: Data.SubSequence, dropping prefix: Int = 0) -> String {
            var bytes = slice.dropFirst(prefix)
            if bytes.last == 0x0D { bytes = bytes.dropLast() }
            return String(decoding: bytes, as: UTF8.self)
        }

        var lines: [DiffLine] = []
        var hunkStarts: [Int] = []
        var i = 0

        // Extended header lines.
        while i < rawLines.count {
            let line = string(rawLines[i])
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("new file mode") { diff.isNew = true; diff.newMode = value(line, after: "new file mode ") }
            else if line.hasPrefix("deleted file mode") { diff.isDeleted = true; diff.oldMode = value(line, after: "deleted file mode ") }
            else if line.hasPrefix("old mode") { diff.oldMode = value(line, after: "old mode ") }
            else if line.hasPrefix("new mode") { diff.newMode = value(line, after: "new mode ") }
            else if line.hasPrefix("similarity index") { diff.similarity = Int(value(line, after: "similarity index ")?.dropLast() ?? "") }
            else if line.hasPrefix("rename from") || line.hasPrefix("rename to") { diff.isRename = true }
            else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { diff.isBinary = true }
            else if line == "--- /dev/null" { diff.isNew = true }
            else if line == "+++ /dev/null" { diff.isDeleted = true }
            i += 1
        }

        // Hunks. Line counts from the @@ header tell us where a hunk ends, so content lines that
        // happen to look like headers ("--- foo", "diff --git") are never misread.
        while i < rawLines.count {
            guard let header = parseHunkHeader(string(rawLines[i])) else { i += 1; continue }
            i += 1
            hunkStarts.append(lines.count)
            var oldNo = header.oldStart, newNo = header.newStart
            var oldLeft = header.oldCount, newLeft = header.newCount

            while i < rawLines.count, oldLeft > 0 || newLeft > 0 || rawLines[i].first == UInt8(ascii: "\\") {
                let raw = rawLines[i]
                switch raw.first {
                case UInt8(ascii: "\\"):
                    if let last = lines.last {
                        lines[lines.count - 1] = DiffLine(kind: last.kind, oldLine: last.oldLine, newLine: last.newLine, text: last.text, missingNewline: true)
                    }
                case UInt8(ascii: "+"):
                    lines.append(DiffLine(kind: .added, oldLine: nil, newLine: newNo, text: string(raw, dropping: 1)))
                    newNo += 1; newLeft -= 1
                case UInt8(ascii: "-"):
                    lines.append(DiffLine(kind: .removed, oldLine: oldNo, newLine: nil, text: string(raw, dropping: 1)))
                    oldNo += 1; oldLeft -= 1
                default: // " " context (or an empty line from a tool that stripped the space)
                    lines.append(DiffLine(kind: .context, oldLine: oldNo, newLine: newNo, text: string(raw, dropping: 1)))
                    oldNo += 1; newNo += 1; oldLeft -= 1; newLeft -= 1
                }
                i += 1
            }
        }

        diff.setLines(lines, hunkStarts: hunkStarts)
        return diff
    }

    private static func value(_ line: String, after prefix: String) -> String? {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private struct HunkHeader { var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int }

    /// `@@ -a[,b] +c[,d] @@ …`
    private static func parseHunkHeader(_ line: String) -> HunkHeader? {
        guard line.hasPrefix("@@ -") else { return nil }
        let body = line.dropFirst(3).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard body.count >= 2, body[0].hasPrefix("-"), body[1].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let parts = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            return (start, parts.count > 1 ? (Int(parts[1]) ?? 1) : 1)
        }
        guard let o = range(body[0]), let n = range(body[1]) else { return nil }
        return HunkHeader(oldStart: o.0, oldCount: o.1, newStart: n.0, newCount: n.1)
    }
}
