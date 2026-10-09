import RevuCore
import SwiftUI

enum Palette {
    static let removed = Color(nsColor: .systemRed).opacity(0.15)
    static let removedWord = Color(nsColor: .systemRed).opacity(0.35)
    static let added = Color(nsColor: .systemGreen).opacity(0.15)
    static let addedWord = Color(nsColor: .systemGreen).opacity(0.35)
    static let filler = Color.secondary.opacity(0.07)
    static let gutterText = Color.secondary
    static let addedBar = Color(nsColor: .systemGreen)
    static let removedBar = Color(nsColor: .systemRed)

    static func background(_ kind: SideCell.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: added
        case .removed: removed
        case .filler: filler
        }
    }

    static func word(_ kind: SideCell.Kind) -> Color { kind == .removed ? removedWord : addedWord }
}

enum Metrics {
    static let gutterWidth: CGFloat = 54
    static let cellPadding: CGFloat = 6

    /// Width of one monospaced character; used to size columns when wrapping is off.
    static func charWidth(_ size: CGFloat) -> CGFloat {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular).maximumAdvancement.width
    }
}

/// One line of code. Draws the finished AttributedString when there is one (syntax colours and
/// word-diff backgrounds, built ahead of time off the main thread) and plain text until then.
/// Equatable so unrelated parent updates (hover, scrolling) never re-run it.
struct CodeText: View, Equatable {
    let text: String
    let styled: AttributedString?
    let size: CGFloat
    let wrap: Bool

    nonisolated static func == (a: CodeText, b: CodeText) -> Bool {
        a.text == b.text && a.size == b.size && a.wrap == b.wrap && (a.styled == nil) == (b.styled == nil)
            && (a.styled == nil || a.styled == b.styled)
    }

    var body: some View {
        Group {
            if let styled { Text(styled) } else { Text(verbatim: text.isEmpty ? " " : text) }
        }
        .font(.system(size: size, design: .monospaced))
        .lineLimit(wrap ? nil : 1)
        .fixedSize(horizontal: !wrap, vertical: true)
        .textSelection(.enabled)
    }
}

/// Line-number gutter with GitHub-style "+" button on hover.
struct Gutter: View {
    let number: Int?
    let size: CGFloat
    let hovering: Bool
    let onAdd: (_ extend: Bool) -> Void
    var onOpen: () -> Void = {}

    var body: some View {
        ZStack(alignment: .leading) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: size - 1, design: .monospaced))
                .foregroundStyle(Palette.gutterText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
            if hovering, number != nil {
                Button {
                    onAdd(NSEvent.modifierFlags.contains(.shift))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .help("Add a comment (shift-click to extend the range)")
            }
        }
        .frame(width: Metrics.gutterWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }
}

/// One side of a Changes-view row.
struct DiffCell: View {
    @Environment(AppState.self) private var state
    let cell: SideCell
    let styled: AttributedString?
    let side: Side
    let file: FileKey
    let size: CGFloat
    let wrap: Bool
    /// File view: a 3pt green bar in the margin of added lines.
    var bar = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if bar {
                Rectangle().fill(cell.kind == .added ? Palette.addedBar : .clear).frame(width: 3)
            }
            Gutter(number: cell.number, size: size, hovering: hovering, onAdd: { extend in
                if let n = cell.number { state.beginComment(file: file, side: side, line: n, extend: extend) }
            }, onOpen: { state.openInEditor(file, line: state.editorLine(for: cell, in: file)) })
            CodeText(text: cell.text, styled: styled, size: size, wrap: wrap)
                .equatable()
                .contextMenu { lineMenu }
                .padding(.horizontal, Metrics.cellPadding)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.background(cell.kind))
        .onHover { inside in
            hovering = inside
            if inside { state.noteHover(cell, in: file) }
        }
        .contextMenu { lineMenu }
    }

    @ViewBuilder private var lineMenu: some View {
        if cell.number != nil, state.canOpenInEditor(file) {
            let line = state.editorLine(for: cell, in: file)
            Button("Open in \(state.externalEditor.name) at Line \(line ?? 1)") { state.openInEditor(file, line: line) }
            Button("Copy path:line") { state.copyPathLine(file, line: line ?? 1) }
        }
    }
}
