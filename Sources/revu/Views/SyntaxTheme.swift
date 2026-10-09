import AppKit
import RevuCore
import SwiftUI

/// Colours for syntax tokens: close to Xcode's default light and dark themes, and chosen to stay
/// readable on top of the green and red row tints.
enum SyntaxTheme {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }

    static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3)
    static let type = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
    static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
    static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)
    static let attribute = dynamic(light: 0x7A5A00, dark: 0xD9A05B)
    static let preprocessor = dynamic(light: 0x643820, dark: 0xFD8F3F)
    static let function = dynamic(light: 0x326D74, dark: 0x67B7A4)
    static let tag = dynamic(light: 0x9B2393, dark: 0xFC5FA3)

    static func color(_ kind: TokenKind) -> Color {
        switch kind {
        case .keyword: keyword
        case .type: type
        case .string: string
        case .number: number
        case .comment: comment
        case .attribute: attribute
        case .preprocessor: preprocessor
        case .function: function
        case .tag: tag
        }
    }

    /// One line with syntax colours and word-diff backgrounds merged. Built off the main thread ahead
    /// of time, so scrolling never has to.
    static func attributed(text: String, tokens: [Token], wordRanges: [Range<Int>], wordColor: Color) -> AttributedString {
        var result = AttributedString(text.isEmpty ? " " : text)
        let length = text.utf16.count
        func range(_ r: Range<Int>) -> Range<AttributedString.Index>? {
            let lo = String.Index(utf16Offset: min(r.lowerBound, length), in: text)
            let hi = String.Index(utf16Offset: min(r.upperBound, length), in: text)
            return lo < hi ? Range(lo..<hi, in: result) : nil
        }
        for token in tokens {
            if let r = range(token.range) { result[r].foregroundColor = color(token.kind) }
        }
        for word in wordRanges {
            if let r = range(word) { result[r].backgroundColor = wordColor }
        }
        return result
    }
}
