import RevuCore
import SwiftUI

/// The new version of the file in one column, with markers where lines were removed.
struct FileContentView: View {
    @Environment(AppState.self) private var state
    let key: FileKey
    let loaded: LoadedFile

    var body: some View {
        let lines = loaded.fileLines
        let size = state.fontSize
        let wrap = state.wrap
        let styleVersion = state.styleVersion(key)
        let width = Metrics.gutterWidth + 3 + Metrics.cellPadding * 2 + CGFloat(loaded.maxLineLength) * Metrics.charWidth(size)

        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(lines) { line in
                        FileLineView(line: line, key: key, loaded: loaded, size: size, wrap: wrap, styleVersion: styleVersion)
                    }
                }
                .frame(minWidth: wrap ? nil : width, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: state.scrollRequest) { performScroll(proxy, lines: lines) }
            .onAppear { performScroll(proxy, lines: lines) }
            .task(id: lines.count) { loaded.want(styleRequests(lines)) }
        }
    }

    private func styleRequests(_ lines: [FileViewLine]) -> [(cell: SideCell, column: LoadedFile.Column)] {
        lines.flatMap { line -> [(cell: SideCell, column: LoadedFile.Column)] in
            switch line.content {
            case let .line(cell): [(cell, cell.kind == .removed ? .fileRemoved : .right)]
            case let .removed(block): block.lines.map { ($0, .fileRemoved) }
            }
        }
    }

    private func performScroll(_ proxy: ScrollViewProxy, lines: [FileViewLine]) {
        guard let request = state.scrollRequest, request.file == key else { return }
        let id: Int?
        switch request.target {
        case let .row(rowID): id = rowID
        case let .line(side, number): id = loaded.diff.lineIndex(side: side, number: number)
        }
        state.scrollRequest = nil
        guard let id else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

struct FileLineView: View {
    @Environment(AppState.self) private var state
    let line: FileViewLine
    let key: FileKey
    let loaded: LoadedFile
    let size: CGFloat
    let wrap: Bool
    /// Changes when styled text becomes available, so the cells redraw.
    let styleVersion: Int

    var body: some View {
        switch line.content {
        case let .line(cell):
            let side: Side = cell.kind == .removed ? .old : .new
            VStack(spacing: 0) {
                DiffCell(cell: cell, styled: loaded.styled(cell, cell.kind == .removed ? .fileRemoved : .right), side: side, file: key, size: size, wrap: wrap, bar: true)
                    .fixedSize(horizontal: false, vertical: true)
                if let number = cell.number {
                    let slot = LineSlot(file: key, side: side, line: number)
                    if state.hasThread(slot) { CommentThread(slot: slot) }
                }
            }

        case let .removed(block):
            let blockKey = RemovedBlockKey(file: key, id: line.id)
            let oldLines = block.lines.compactMap(\.number)
            let expanded = state.isRemovedExpanded(blockKey, oldLines: oldLines)
            VStack(spacing: 0) {
                Button {
                    state.toggleRemoved(blockKey, oldLines: oldLines)
                } label: {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Palette.removedBar).frame(height: 2).frame(maxWidth: .infinity)
                        Text("−\(block.lines.count)")
                            .font(.system(size: size - 2, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .background(Palette.removedBar, in: Capsule())
                            .padding(.leading, 6)
                    }
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide removed lines" : "Show \(block.lines.count) removed line\(block.lines.count == 1 ? "" : "s")")

                if expanded {
                    ForEach(Array(block.lines.enumerated()), id: \.offset) { _, cell in
                        VStack(spacing: 0) {
                            DiffCell(cell: cell, styled: loaded.styled(cell, .fileRemoved), side: .old, file: key, size: size, wrap: wrap, bar: true)
                                .fixedSize(horizontal: false, vertical: true)
                            if let number = cell.number {
                                let slot = LineSlot(file: key, side: .old, line: number)
                                if state.hasThread(slot) { CommentThread(slot: slot) }
                            }
                        }
                    }
                }
            }
        }
    }
}
