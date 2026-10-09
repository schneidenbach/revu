import Foundation

/// An external editor that can open a file at a line through a URL scheme (no CLI needed).
public enum Editor: String, CaseIterable, Sendable {
    case vscode, cursor, vscodeInsiders = "vscode-insiders", zed

    public var name: String {
        switch self {
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .vscodeInsiders: "VS Code Insiders"
        case .zed: "Zed"
        }
    }

    /// The URL scheme the editor registers (also the value accepted in `REVU_EDITOR`).
    public var scheme: String { rawValue }

    /// `scheme://file/<absolute path>:<line>:<column>`, with the path percent-encoded (slashes kept).
    public func url(path: String, line: Int? = nil, column: Int = 1) -> URL {
        var text = "\(scheme)://file" + Self.encode(path)
        if let line { text += ":\(line):\(column)" }
        return URL(string: text)!
    }

    private static let pathAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/@+,;=!$&'()*")

    private static func encode(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : "/" + path
        // ':' is encoded so a colon in a directory name can't be mistaken for the `:line:column` suffix.
        return absolute.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? absolute
    }

    /// Reads `REVU_EDITOR`: nil or empty means VS Code; an unknown value falls back to VS Code with a warning.
    public static func fromEnvironment(_ value: String?) -> (editor: Editor, warning: String?) {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return (.vscode, nil) }
        if let editor = Editor(rawValue: raw.lowercased()) { return (editor, nil) }
        let known = allCases.map(\.rawValue).joined(separator: ", ")
        return (.vscode, "unknown REVU_EDITOR '\(raw)' (expected \(known)); using vscode")
    }
}
