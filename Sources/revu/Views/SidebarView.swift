import RevuCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selection) {
            ForEach(state.repos) { repo in
                let files = state.visibleFiles(in: repo)
                if !files.isEmpty || state.filter.isEmpty {
                    Section(isExpanded: Binding(
                        get: { !state.collapsedRepos.contains(repo.id) },
                        set: { if $0 { state.collapsedRepos.remove(repo.id) } else { state.collapsedRepos.insert(repo.id) } }
                    )) {
                        ForEach(files) { file in FileRow(file: file) }
                    } header: {
                        RepoHeader(repo: repo, shown: files.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.selection) { _, key in state.didSelect(key) }
        .searchable(text: $state.filter, placement: .sidebar, prompt: "Filter files")
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }
}

struct RepoHeader: View {
    let repo: RepoSnapshot
    let shown: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(repo.context.displayName).font(.headline).lineLimit(1)
                if repo.context.isWorktree {
                    Text("worktree")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text("\(repo.files.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("\(repo.context.branch ?? "detached HEAD") → \(repo.base.ref)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .help(repo.context.root)
    }
}

struct FileRow: View {
    @Environment(AppState.self) private var state
    let file: ChangedFile

    var body: some View {
        let viewed = state.isViewed(file.key)
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        let comments = state.commentCount(file.key)
        let changedSinceViewed = state.changedSinceViewed.contains(file.key)

        HStack(spacing: 6) {
            StatusGlyph(status: file.status)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(name).fontWeight(.semibold).lineLimit(1)
                    if changedSinceViewed {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                            .help("Changed since you viewed it")
                    }
                }
                if !dir.isEmpty {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.isGenerated {
                Text("generated")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if file.isBinary {
                Text("bin").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("+\(file.additions)").foregroundStyle(.green)
                    Text("−\(file.deletions)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
            }
            if comments > 0 {
                Label("\(comments)", systemImage: "text.bubble.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            }
            Toggle("Viewed", isOn: Binding(get: { viewed }, set: { state.setViewed(file.key, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Mark as viewed")
        }
        .opacity(viewed ? 0.5 : (file.isGenerated ? 0.6 : 1))
        .help(file.path)
    }
}

struct StatusGlyph: View {
    let status: ChangeStatus

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        switch status {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        case .typeChanged: .purple
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text("+\(state.totalAdditions)").foregroundStyle(.green)
                Text("−\(state.totalDeletions)").foregroundStyle(.red)
            }
            Text("\(state.viewedCount)/\(state.totalFiles) viewed")
            Text("\(state.comments.count) comment\(state.comments.count == 1 ? "" : "s")")
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
