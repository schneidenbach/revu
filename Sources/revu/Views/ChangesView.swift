import RevuCore
import SwiftUI

/// Side-by-side diff for one file.
struct ChangesView: View {
    @Environment(AppState.self) private var state
    let key: FileKey
    let loaded: LoadedFile

    var body: some View {
        let rows = loaded.sideRows(
            expandedRuns: state.expandedRuns(key), expandAll: state.isExpandedAll(key),
            pinned: state.pinnedLines(key, in: loaded))
        let size = state.fontSize
        let wrap = state.wrap
        let styleVersion = state.styleVersion(key)
        let columnWidth = Metrics.gutterWidth + Metrics.cellPadding * 2
            + CGFloat(loaded.maxLineLength) * Metrics.charWidth(size)

        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        SideBySideRowView(row: row, key: key, loaded: loaded, size: size, wrap: wrap, styleVersion: styleVersion)
                    }
                }
                .frame(minWidth: wrap ? nil : columnWidth * 2 + 1, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: state.scrollRequest) { performScroll(proxy, rows: rows) }
            .onAppear { performScroll(proxy, rows: rows) }
            // Ask for styled text for what is on offer; it is built off the main thread and swapped in.
            .task(id: RowsSignature(rows: rows)) { loaded.want(styleRequests(rows)) }
        }
    }

    private struct RowsSignature: Equatable {
        let count: Int, first: Int?, last: Int?
        init(rows: [SideBySideRow]) { count = rows.count; first = rows.first?.id; last = rows.last?.id }
    }

    private func styleRequests(_ rows: [SideBySideRow]) -> [(cell: SideCell, column: LoadedFile.Column)] {
        rows.flatMap { row -> [(cell: SideCell, column: LoadedFile.Column)] in
            guard case let .pair(left, right) = row.content else { return [] }
            return [(left, .left), (right, .right)]
        }
    }

    private func performScroll(_ proxy: ScrollViewProxy, rows: [SideBySideRow]) {
        guard let request = state.scrollRequest, request.file == key else { return }
        let id: Int?
        switch request.target {
        case let .row(rowID): id = rowID
        case let .line(side, number):
            id = loaded.diff.lineIndex(side: side, number: number).flatMap { loaded.sideRowID(forDiffIndex: $0, rows: rows) }
        }
        state.scrollRequest = nil
        guard let id else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

struct SideBySideRowView: View {
    @Environment(AppState.self) private var state
    let row: SideBySideRow
    let key: FileKey
    let loaded: LoadedFile
    let size: CGFloat
    let wrap: Bool
    /// Changes when styled text becomes available, so the cells redraw.
    let styleVersion: Int

    var body: some View {
        switch row.content {
        case let .collapsed(hidden, runStart):
            Button {
                state.expandRun(key, runStart: runStart)
            } label: {
                Text("⋯  \(hidden) unchanged line\(hidden == 1 ? "" : "s")")
                    .font(.system(size: size - 1))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show unchanged lines")

        case let .pair(left, right):
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    DiffCell(cell: left, styled: loaded.styled(left, .left), side: .old, file: key, size: size, wrap: wrap)
                    Rectangle().fill(.separator).frame(width: 1)
                    DiffCell(cell: right, styled: loaded.styled(right, .right), side: .new, file: key, size: size, wrap: wrap)
                }
                .fixedSize(horizontal: false, vertical: true)

                let leftSlot = left.number.map { LineSlot(file: key, side: .old, line: $0) }
                let rightSlot = right.number.map { LineSlot(file: key, side: .new, line: $0) }
                let leftHas = leftSlot.map(state.hasThread) ?? false
                let rightHas = rightSlot.map(state.hasThread) ?? false
                if leftHas || rightHas {
                    HStack(alignment: .top, spacing: 0) {
                        Group { if leftHas, let leftSlot { CommentThread(slot: leftSlot) } else { Color.clear.frame(height: 0) } }
                            .frame(maxWidth: .infinity)
                        Group { if rightHas, let rightSlot { CommentThread(slot: rightSlot) } else { Color.clear.frame(height: 0) } }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
