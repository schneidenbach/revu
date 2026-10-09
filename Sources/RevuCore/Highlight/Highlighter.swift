import Foundation

/// Token ranges for every diff line, one set per side. Index = index into `FileDiff.lines`;
/// ranges are UTF-16 offsets into the tab-expanded display text of that line.
public struct DiffHighlights: Sendable, Equatable {
    /// Tokens of context and added lines, as part of the new file.
    public var new: [[Token]]
    /// Tokens of context and removed lines, as part of the old file.
    public var old: [[Token]]

    public func tokens(side: Side, diffIndex: Int) -> [Token] {
        let source = side == .new ? new : old
        return diffIndex < source.count ? source[diffIndex] : []
    }
}

public enum Highlighter {
    public static let maxLineLength = 2_000
    public static let maxLines = 100_000

    /// Lexes each side of the diff as its own file, so multi-line comments and strings carry across
    /// the lines of that side correctly. Returns nil for files that are too large to bother with.
    /// Over-long lines are left plain and do not disturb the state.
    public static func highlight(diff: FileDiff, language: Language) -> DiffHighlights? {
        guard diff.lines.count <= maxLines else { return nil }
        var new = [[Token]](repeating: [], count: diff.lines.count)
        var old = new
        var newState = LexState.normal
        var oldState = LexState.normal

        for (i, line) in diff.lines.enumerated() {
            guard line.text.utf16.count <= maxLineLength else { continue }
            let text = DisplayText.expandTabs(line.text)
            if line.newLine != nil {
                let result = Lexer.lex(text, language: language, state: newState)
                new[i] = result.tokens
                newState = result.state
            }
            if line.oldLine != nil {
                let result = Lexer.lex(text, language: language, state: oldState)
                old[i] = result.tokens
                oldState = result.state
            }
        }
        return DiffHighlights(new: new, old: old)
    }

    /// Language for a diff, using the first line of the file for shebang detection.
    public static func language(for diff: FileDiff) -> Language? {
        Language.detect(path: diff.path, firstLine: diff.lines.first { $0.newLine != nil }?.text ?? diff.lines.first?.text)
    }
}
