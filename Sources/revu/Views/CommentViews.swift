import RevuCore
import SwiftUI

/// Editor and saved comments hanging under one line (or under the file header for file-level comments).
struct CommentThread: View {
    @Environment(AppState.self) private var state
    let slot: LineSlot

    var body: some View {
        VStack(spacing: 8) {
            ForEach(state.comments(at: slot)) { comment in
                if state.editor?.editing == comment.id {
                    CommentEditor()
                } else {
                    CommentCard(comment: comment)
                }
            }
            if let editor = state.editorState(for: slot), editor.editing == nil {
                CommentEditor()
            }
        }
        .padding(8)
    }
}

struct FileCommentThread: View {
    @Environment(AppState.self) private var state
    let file: FileKey

    var body: some View {
        let comments = state.fileComments(file)
        let editing = state.editor.map { $0.anchor.fileKey == file && $0.anchor.isFileLevel } ?? false
        if !comments.isEmpty || editing {
            VStack(spacing: 8) {
                ForEach(comments) { comment in
                    if state.editor?.editing == comment.id { CommentEditor() } else { CommentCard(comment: comment) }
                }
                if editing, state.editor?.editing == nil { CommentEditor() }
            }
            .padding(8)
        }
    }
}

struct CommentCard: View {
    @Environment(AppState.self) private var state
    let comment: Comment

    var body: some View {
        let outdated = state.isOutdated(comment)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                Text(label).font(.caption).foregroundStyle(.secondary)
                if outdated {
                    Text("Outdated")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .help("The commented lines have changed since this comment was written")
                }
                Spacer()
                Button("Edit") { state.beginEdit(comment) }.buttonStyle(.link).font(.caption)
                Button("Delete") { state.delete(comment) }.buttonStyle(.link).font(.caption)
            }
            Text(comment.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private var label: String {
        let a = comment.anchor
        guard let start = a.startLine else { return "File comment" }
        let end = a.endLine ?? start
        let removed = a.side == .old ? " (removed)" : ""
        return (start == end ? "Line \(start)" : "Lines \(start)–\(end)") + removed
    }
}

struct CommentEditor: View {
    @Environment(AppState.self) private var state
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            if let anchor = state.editor?.anchor, let start = anchor.startLine {
                let end = anchor.endLine ?? start
                Text(start == end ? "Comment on line \(start)" : "Comment on lines \(start)–\(end)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $state.editorText)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 70, maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("Cancel") { state.cancelEditor() }
                    .keyboardShortcut(.cancelAction)
                Button(state.editor?.editing == nil ? "Comment" : "Save") { state.saveEditor() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)))
        .onAppear { focused = true }
    }
}
