import RevuCore
import SwiftUI

struct DetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            if let count = state.restoredCount {
                HStack {
                    Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(.blue)
                    Text("Restored \(count) draft comment\(count == 1 ? "" : "s")")
                    Spacer()
                    Button { state.restoredCount = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.blue.opacity(0.12))
                Divider()
            }
            if let error = state.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Refresh failed: \(error)").lineLimit(2)
                    Spacer()
                    Button { state.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.orange.opacity(0.12))
                Divider()
            }

            if let file = state.selectedFile {
                FileHeader(file: file)
                Divider()
                FileBody(file: file).id(file.key)
            } else if state.totalFiles == 0 {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                       description: Text("Nothing differs from the base in the given directories."))
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct FileHeader: View {
    @Environment(AppState.self) private var state
    let file: ChangedFile

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StatusGlyph(status: file.status)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.absolutePath, forType: .string)
                } label: {
                    if let old = file.oldPath {
                        Text("\(old) → \(file.path)")
                    } else {
                        Text(file.path)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
                .help("Click to copy the absolute path")

                Spacer()

                if state.mode == .changes, case .ready = state.diffState(file.key), !state.isExpandedAll(file.key) {
                    Button("Expand all") { state.expandAll(file.key) }
                }
                Button {
                    state.openSelectedInEditor()
                } label: {
                    Label("Open in \(state.externalEditor.name)", systemImage: "arrow.up.forward.app")
                }
                .disabled(!state.canOpenInEditor(file.key))
                .help(state.canOpenInEditor(file.key) ? "Open in \(state.externalEditor.name) (⇧⌘O)" : "This file was deleted")
                Button {
                    state.beginFileComment(file.key)
                } label: {
                    Label("Comment on file", systemImage: "text.bubble")
                }
                Toggle("Viewed", isOn: Binding(get: { state.isViewed(file.key) }, set: { state.setViewed(file.key, $0) }))
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            FileCommentThread(file: file.key)
        }
        .background(.bar)
    }
}

/// Loads (if needed) and shows the selected file in the current mode.
struct FileBody: View {
    @Environment(AppState.self) private var state
    let file: ChangedFile

    var body: some View {
        switch state.diffState(file.key) {
        case nil:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { state.ensureLoaded(file.key) }
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView("Could not load diff", systemImage: "exclamationmark.triangle", description: Text(message))
        case let .binary(info):
            ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text(binaryDescription(info)))
        case let .tooLarge(reason):
            ContentUnavailableView {
                Label(reason.title, systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(reason.detail)
            } actions: {
                Button("Load diff") { state.ensureLoaded(file.key, force: true) }
            }
        case .generated:
            ContentUnavailableView {
                Label("Generated file", systemImage: "gearshape.2")
            } description: {
                Text("Lock files, minified output and migrations are collapsed by default.")
            } actions: {
                Button("Load diff") { state.ensureLoaded(file.key, force: true) }
            }
        case let .ready(loaded):
            if loaded.diff.lines.isEmpty {
                ContentUnavailableView("No content changes", systemImage: "doc", description: Text(emptyDescription(loaded.diff)))
            } else if state.mode == .changes {
                ChangesView(key: file.key, loaded: loaded)
            } else {
                FileContentView(key: file.key, loaded: loaded)
            }
        }
    }

    private func binaryDescription(_ info: BinaryInfo) -> String {
        func size(_ n: Int?) -> String { n.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—" }
        return "Old: \(size(info.oldSize))   New: \(size(info.newSize))"
    }

    private func emptyDescription(_ diff: FileDiff) -> String {
        if let old = diff.oldMode, let new = diff.newMode, old != new { return "File mode changed from \(old) to \(new)." }
        if diff.isNew { return "Empty file." }
        return "This file has no textual differences."
    }
}

private extension LargeReason {
    var title: String {
        switch self {
        case let .changedLines(n): "Large diff — \(n.formatted()) changed lines"
        case .bytes: "Large file"
        }
    }

    var detail: String {
        switch self {
        case .changedLines: "Loading it may take a moment."
        case let .bytes(n): "This file is \(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)). Loading it may take a moment."
        }
    }
}
