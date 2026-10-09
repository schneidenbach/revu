import Foundation
import RevuCore

/// Where a file's diff is in its life cycle; what the detail view switches on.
enum DiffState {
    case loading
    case failed(String)
    case binary(BinaryInfo)
    case tooLarge(LargeReason)
    case generated
    case ready(LoadedFile)
}

/// A parsed diff plus the row models derived from it, cached so scrolling and unrelated state
/// changes never recompute them. Also owns the syntax-highlighted text of its lines: tokens are
/// computed off the main thread, and every cell's AttributedString is built there too, so row views
/// only ever look a finished string up.
@MainActor
final class LoadedFile {
    let diff: FileDiff
    private var cachedSide: (key: SideKey, rows: [SideBySideRow])?
    private struct SideKey: Equatable { var expanded: Set<Int>; var all: Bool; var pinned: Set<Int> }

    init(diff: FileDiff) {
        self.diff = diff
        language = Highlighter.language(for: diff)
        highlighting = language == nil ? .unavailable : .pending
    }

    func sideRows(expandedRuns: Set<Int>, expandAll: Bool, pinned: Set<Int>) -> [SideBySideRow] {
        let key = SideKey(expanded: expandedRuns, all: expandAll, pinned: pinned)
        if let cachedSide, cachedSide.key == key { return cachedSide.rows }
        let rows = SideBySide.build(diff: diff, expandedRuns: expandedRuns, expandAll: expandAll, pinned: pinned)
        cachedSide = (key, rows)
        return rows
    }

    lazy var fileLines: [FileViewLine] = FileViewModel.build(diff: diff)

    /// Longest displayed line in characters; sizes the columns when wrapping is off.
    lazy var maxLineLength: Int = diff.lines.reduce(0) { best, line in
        max(best, DisplayText.expandTabs(line.text).utf16.count)
    }

    func changeStarts(in rows: [SideBySideRow]) -> [Int] {
        rows.indices.filter { rows[$0].isChange && ($0 == 0 || !rows[$0 - 1].isChange) }.map { rows[$0].id }
    }

    lazy var fileChangeStarts: [Int] = {
        let lines = fileLines
        func isChange(_ l: FileViewLine) -> Bool {
            switch l.content {
            case .removed: true
            case let .line(c): c.kind == .added || c.kind == .removed
            }
        }
        return lines.indices.filter { isChange(lines[$0]) && ($0 == 0 || !isChange(lines[$0 - 1])) }.map { lines[$0].id }
    }()

    /// Id of the Changes-view row that shows the given diff line.
    func sideRowID(forDiffIndex index: Int, rows: [SideBySideRow]) -> Int? {
        rows.first {
            if case let .pair(l, r) = $0.content { return l.diffIndex == index || r.diffIndex == index }
            return false
        }?.id
    }

    // MARK: Syntax highlighting

    /// Which cell of which view a styled string belongs to. The File view's added/context lines are
    /// identical to the Changes view's right cells, so they share `.right`.
    enum Column: Hashable, Sendable { case left, right, fileRemoved }
    struct CellKey: Hashable, Sendable {
        let diffIndex: Int
        let column: Column
    }

    private enum Highlighting {
        case pending
        case ready(DiffHighlights)
        /// Unknown language, or a file past the size guardrails.
        case unavailable
    }

    let language: Language?
    private var highlighting: Highlighting
    private var wanted: [CellKey: SideCell] = [:]
    private var styledStore: [CellKey: AttributedString] = [:]
    private var settled: Set<CellKey> = []
    private var inFlight: Set<CellKey> = []
    /// Called (on the main actor) whenever new styled strings are available.
    var onStyleChange: (@MainActor () -> Void)?

    /// Lexes both sides of the diff off the main thread, then builds whatever styled strings the views asked for.
    func startHighlighting() {
        guard let language else { return }
        let diff = self.diff
        Task.detached(priority: .userInitiated) {
            let result = Highlighter.highlight(diff: diff, language: language)
            await MainActor.run {
                self.highlighting = result.map { .ready($0) } ?? .unavailable
                self.ensurePrepared()
            }
        }
    }

    /// Registers cells the view is about to show and prepares their styled text in the background.
    func want(_ requests: [(cell: SideCell, column: Column)]) {
        for (cell, column) in requests {
            guard let index = cell.diffIndex, cell.kind != .filler else { continue }
            let key = CellKey(diffIndex: index, column: column)
            if wanted[key] == nil { wanted[key] = cell }
        }
        ensurePrepared()
    }

    /// The finished attributed string for a cell, or nil (draw plain text) if it isn't ready or needs none.
    func styled(_ cell: SideCell, _ column: Column) -> AttributedString? {
        guard let index = cell.diffIndex else { return nil }
        return styledStore[CellKey(diffIndex: index, column: column)]
    }

    private func ensurePrepared() {
        if case .pending = highlighting { return }
        let highlights: DiffHighlights?
        if case let .ready(h) = highlighting { highlights = h } else { highlights = nil }
        let todo = wanted.filter { !settled.contains($0.key) && !inFlight.contains($0.key) }
        guard !todo.isEmpty else { return }
        inFlight.formUnion(todo.keys)
        let items = Array(todo)
        Task.detached(priority: .userInitiated) {
            let chunkSize = 3_000
            for start in stride(from: 0, to: items.count, by: chunkSize) {
                var done: [(CellKey, AttributedString?)] = []
                for (key, cell) in items[start..<min(start + chunkSize, items.count)] {
                    done.append((key, Self.style(cell, key.column, highlights)))
                }
                let batch = done
                await MainActor.run { self.merge(batch) }
            }
        }
    }

    private func merge(_ batch: [(CellKey, AttributedString?)]) {
        for (key, string) in batch {
            inFlight.remove(key)
            settled.insert(key)
            if let string { styledStore[key] = string }
        }
        onStyleChange?()
    }

    private nonisolated static func style(_ cell: SideCell, _ column: Column, _ highlights: DiffHighlights?) -> AttributedString? {
        let side: Side = column == .right ? .new : .old
        let tokens = cell.diffIndex.flatMap { highlights?.tokens(side: side, diffIndex: $0) } ?? []
        if tokens.isEmpty && cell.changedRanges.isEmpty { return nil }
        return SyntaxTheme.attributed(text: cell.text, tokens: tokens, wordRanges: cell.changedRanges, wordColor: Palette.word(cell.kind))
    }
}
