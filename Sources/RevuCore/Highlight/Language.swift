import Foundation

public enum Language: String, CaseIterable, Sendable {
    case csharp, typescript, javascript, swift, json, sql, python, shell, yaml, xml, css, markdown, dockerfile, powershell

    private static let byExtension: [String: Language] = [
        "cs": .csharp, "csx": .csharp,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "swift": .swift,
        "json": .json, "jsonc": .json, "json5": .json, "webmanifest": .json,
        "sql": .sql,
        "py": .python, "pyi": .python,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell,
        "yml": .yaml, "yaml": .yaml,
        "xml": .xml, "html": .xml, "htm": .xml, "xhtml": .xml, "svg": .xml, "csproj": .xml, "vbproj": .xml,
        "fsproj": .xml, "props": .xml, "targets": .xml, "xaml": .xml, "razor": .xml, "cshtml": .xml, "config": .xml,
        "resx": .xml, "nuspec": .xml, "plist": .xml, "slnx": .xml, "axaml": .xml, "vue": .xml,
        "css": .css, "scss": .css,
        "md": .markdown, "markdown": .markdown,
        "dockerfile": .dockerfile,
        "ps1": .powershell, "psm1": .powershell, "psd1": .powershell,
    ]

    /// Detects the language from the file name, falling back to a shebang on the first line.
    public static func detect(path: String, firstLine: String? = nil) -> Language? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") { return .dockerfile }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty { return byExtension[ext] }
        guard let line = firstLine, line.hasPrefix("#!") else { return nil }
        let words = line.dropFirst(2).split(separator: " ").map(String.init)
        guard var interpreter = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if interpreter == "env", words.count > 1 { interpreter = words[1] }
        switch interpreter {
        case "sh", "bash", "zsh", "ksh", "dash": return .shell
        case _ where interpreter.hasPrefix("python"): return .python
        case "node", "deno", "bun": return .javascript
        case "pwsh", "powershell": return .powershell
        case "swift": return .swift
        default: return nil
        }
    }
}

public enum TokenKind: String, Sendable {
    case keyword, type, string, number, comment, attribute, preprocessor, function, tag
}

public struct Token: Sendable, Equatable {
    /// UTF-16 offsets into the (tab-expanded) line the token was lexed from.
    public let range: Range<Int>
    public let kind: TokenKind

    public init(_ range: Range<Int>, _ kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// What carries over from one line to the next while lexing a file.
public struct LexState: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        case normal
        case blockComment
        /// C# `@"..."`.
        case verbatimString
        /// C# `"""..."""` with this many quotes.
        case rawString(Int)
        /// Swift `"""..."""`.
        case multilineString
        /// JS/TS template literal.
        case template
        /// Python `'''`/`"""` with this quote character.
        case tripleQuote(UInt16)
        case xmlComment
        /// Inside an XML/HTML tag (attributes continue on the next line).
        case xmlTag
        /// Inside a quoted XML attribute value that spans lines.
        case xmlQuote(UInt16)
        /// Markdown fenced code block.
        case fence
    }

    public var mode: Mode
    public static let normal = LexState(mode: .normal)
}
