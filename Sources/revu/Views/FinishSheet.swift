import RevuCore
import SwiftUI

struct FinishSheet: View {
    @Environment(AppState.self) private var state
    @State private var submitting = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish review").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.headline)
                TextEditor(text: $state.summary)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 110)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }

            Picker("Verdict", selection: Binding(get: { state.effectiveVerdict }, set: { state.chosenVerdict = $0 })) {
                ForEach(Verdict.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(state.comments.count) comment\(state.comments.count == 1 ? "" : "s")").font(.headline)
                CommentList()
                    .frame(minHeight: 160)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }

            HStack {
                Spacer()
                Button("Cancel") { state.showFinish = false }.keyboardShortcut(.cancelAction)
                Button("Submit") {
                    submitting = true
                    Task { await state.submit() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(submitting)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct CommentList: View {
    @Environment(AppState.self) private var state

    private struct Group: Identifiable {
        let key: FileKey
        let comments: [Comment]
        var id: FileKey { key }
    }

    private var groups: [Group] {
        var order: [FileKey] = []
        var map: [FileKey: [Comment]] = [:]
        for comment in state.comments {
            let key = comment.anchor.fileKey
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(comment)
        }
        return order.map { Group(key: $0, comments: map[$0]!) }
    }

    var body: some View {
        if state.comments.isEmpty {
            Text("No comments yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.comments) { comment in
                            Button { state.jump(to: comment) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(location(comment)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)
                                    Text(comment.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(group.key.path).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func location(_ comment: Comment) -> String {
        let a = comment.anchor
        guard let start = a.startLine else { return "file" }
        let end = a.endLine ?? start
        return (a.side == .old ? "−" : "") + (start == end ? "\(start)" : "\(start)–\(end)")
    }
}
