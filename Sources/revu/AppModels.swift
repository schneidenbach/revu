import Foundation
import RevuCore

/// Side-by-side diff or the whole new file.
enum ViewMode: Hashable {
    case changes, file
}

/// Asks the visible diff view to scroll somewhere. The id makes repeated requests for the same target distinct.
struct ScrollRequest: Equatable {
    enum Target: Equatable {
        case row(Int)
        case line(side: Side, number: Int)
    }
    let id = UUID()
    let file: FileKey
    let target: Target
}

/// Which line (or file) the open comment editor is attached to. The text lives in
/// `AppState.editorText` so typing only invalidates the editor itself, not every visible row.
struct EditorState: Equatable {
    var anchor: Anchor
    /// Set when editing an existing comment.
    var editing: UUID?
}

/// One line on one side of one file: the key comment threads hang from.
struct LineSlot: Hashable {
    let file: FileKey
    let side: Side
    let line: Int
}

/// A block of removed lines in the File view (`id` is `FileViewLine.id`).
struct RemovedBlockKey: Hashable {
    let file: FileKey
    let id: Int
}
