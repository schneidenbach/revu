import AppKit
import RevuCore

/// Opening the selected file, or one line of it, in an external editor.
extension AppState {
    /// Whether the file exists in the working tree (deleted files have nothing to open).
    func canOpenInEditor(_ key: FileKey?) -> Bool {
        guard let key, let file = file(key) else { return false }
        return file.status != .deleted
    }

    /// The working-tree line to open for a cell (see `FileDiff.editorLine`), if the diff is loaded.
    func editorLine(for cell: SideCell, in key: FileKey) -> Int? {
        guard let index = cell.diffIndex else { return nil }
        return loadedFile(key)?.diff.editorLine(forDiffIndex: index)
    }

    func noteHover(_ cell: SideCell, in key: FileKey) {
        if let line = editorLine(for: cell, in: key) { lastHoveredLine = (key, line) }
    }

    /// Opens `key` in the editor at `line` (line 1 if nil). Returns false if nothing was opened.
    @discardableResult
    func openInEditor(_ key: FileKey, line: Int?) -> Bool {
        guard canOpenInEditor(key), let file = file(key) else { return false }
        let url = externalEditor.url(path: file.absolutePath, line: line ?? 1)
        guard openURL(url) else {
            presentEditorMissing(
                "\(externalEditor.name) could not be opened",
                "Nothing handled \(url.scheme ?? externalEditor.scheme)://. Is \(externalEditor.name) installed? "
                    + "Set REVU_EDITOR to one of \(Editor.allCases.map(\.rawValue).joined(separator: ", ")) to use another editor.")
            return false
        }
        return true
    }

    /// ⇧⌘O: the selected file, at the line last hovered in it (else line 1).
    func openSelectedInEditor() {
        guard let key = selection else { return }
        let line = lastHoveredLine.flatMap { $0.file == key ? $0.line : nil }
        openInEditor(key, line: line)
    }

    func copyPathLine(_ key: FileKey, line: Int?) {
        guard let file = file(key) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.map { "\(file.absolutePath):\($0)" } ?? file.absolutePath, forType: .string)
    }
}
