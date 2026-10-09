import AppKit
import Observation
import RevuCore

/// Everything the window shows and edits: repos, selection, cached diffs, comments and viewed marks.
/// Live refresh lives in AppState+Refresh.swift and opening files in an editor in AppState+Editor.swift.
@MainActor @Observable
final class AppState {
    // MARK: Data
    var repos: [RepoSnapshot]
    let options: Options
    /// Which editor "Open in …" uses (from `REVU_EDITOR`, read once at launch).
    let externalEditor: Editor
    /// Opens a URL with the system; false if nothing handles it. Replaced in tests.
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Tells the user an editor could not be opened. Replaced in tests.
    var presentEditorMissing: (_ title: String, _ detail: String) -> Void = { title, detail in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
    /// The line most recently hovered in each view, used by ⇧⌘O. Not observed: nothing draws from it.
    @ObservationIgnored var lastHoveredLine: (file: FileKey, line: Int)?

    // MARK: Selection and view settings
    var selection: FileKey?
    var mode: ViewMode = .changes
    var wrap = true
    var fontSize: CGFloat = 12
    var filter = ""
    var collapsedRepos: Set<String> = []
    var isRefreshing = false
    var lastError: String?

    // MARK: Review state
    private(set) var comments: [Comment] = []
    var summary = "" { didSet { scheduleDraftSave() } }
    /// Viewed files and the fingerprint of the diff that was viewed.
    var viewed: [FileKey: String] = [:]
    /// Files un-viewed automatically because their diff changed; marked in the sidebar until selected.
    var changedSinceViewed: Set<FileKey> = []
    /// Set for a few seconds after an automatic (file-watching) refresh.
    var showUpdatedToast = false
    var chosenVerdict: Verdict?
    var showFinish = false
    var restoredCount: Int?
    private(set) var editor: EditorState?
    var editorText = ""

    // MARK: Diff cache and expansion
    var diffStates: [FileKey: DiffState] = [:]
    /// Bumped when a file's styled text changes, so its views redraw their cells.
    private(set) var styleVersions: [FileKey: Int] = [:]
    private(set) var expandedRuns: [FileKey: Set<Int>] = [:]
    private(set) var expandedAll: Set<FileKey> = []
    /// Explicit user choice per removed block; without one, a block is open iff it holds a comment.
    private var removedOverride: [RemovedBlockKey: Bool] = [:]
    var scrollRequest: ScrollRequest?
    private(set) var changeCursor: [FileKey: Int] = [:]
    /// Lets only the newest load of a file publish its result.
    var loadGate = LoadGate()
    /// Files the user chose to load despite a large/generated placeholder; kept across refreshes.
    private var forcedLoads: Set<FileKey> = []
    /// Cached diffs of files in refreshed repos: still shown if looked at, but reloaded when selected.
    var staleKeys: Set<FileKey> = []

    // Refresh scheduling; driven by AppState+Refresh.swift.
    var coalescer: RefreshCoalescer
    var retry: RefreshRetryPolicy
    var dirtyRoots: Set<String> = []
    var manualRequested = false
    var refreshDriver: Task<Void, Never>?
    var toastTask: Task<Void, Never>?
    var watchers: [RepoWatcher] = []
    /// How many refreshes have been started (for tests).
    var refreshAttempts = 0

    // MARK: Derived comment indexes
    private var byLine: [LineSlot: [Comment]] = [:]
    private var byFile: [FileKey: [Comment]] = [:]

    private let drafts: DraftStore
    private let archive: ReviewArchive
    private var saveTask: Task<Void, Never>?

    init(
        snapshots: [RepoSnapshot], options: Options, drafts: DraftStore = DraftStore(), archive: ReviewArchive = ReviewArchive(),
        refreshDelay: TimeInterval = 0.4, retryDelay: TimeInterval = 1.5, externalEditor: Editor = .vscode
    ) {
        self.externalEditor = externalEditor
        self.coalescer = RefreshCoalescer(delay: refreshDelay)
        self.retry = RefreshRetryPolicy(delay: retryDelay)
        self.repos = snapshots
        self.options = options
        self.drafts = drafts
        self.archive = archive
        if let draft = drafts.load(roots: snapshots.map(\.context.root)) {
            comments = draft.comments
            summary = draft.summary
            viewed = draft.viewed
            rebuildCommentIndex()
            if !draft.comments.isEmpty { restoredCount = draft.comments.count }
        }
        selection = allFiles.first?.key
        if let selection { ensureLoaded(selection) }
        // Viewed marks carry over from an earlier round: keep the unchanged files, flag the changed ones.
        if !viewed.isEmpty { Task { await recheckViewed() } }
    }

    // MARK: Files

    var allFiles: [ChangedFile] { repos.flatMap { visibleFiles(in: $0) } }

    func visibleFiles(in repo: RepoSnapshot) -> [ChangedFile] {
        guard !filter.isEmpty else { return repo.files }
        return repo.files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    func file(_ key: FileKey) -> ChangedFile? {
        repos.first { $0.context.root == key.repoRoot }?.files.first { $0.path == key.path }
    }

    func repo(_ key: FileKey) -> RepoSnapshot? { repos.first { $0.context.root == key.repoRoot } }

    var selectedFile: ChangedFile? { selection.flatMap(file) }

    var totalFiles: Int { repos.reduce(0) { $0 + $1.files.count } }
    var totalAdditions: Int { repos.flatMap(\.files).reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { repos.flatMap(\.files).reduce(0) { $0 + $1.deletions } }
    var viewedCount: Int { repos.flatMap(\.files).filter { viewed[$0.key] != nil }.count }

    var windowTitle: String {
        if let title = options.title { return title }
        let n = repos.count
        return "revu — \(n) repo\(n == 1 ? "" : "s"), \(totalFiles) file\(totalFiles == 1 ? "" : "s")"
    }

    func select(_ key: FileKey?) {
        selection = key
        didSelect(key)
    }

    /// Side effects of a selection change. The sidebar List calls this from `onChange` rather than from
    /// its selection binding: changing the rows (the "changed since viewed" dot) while NSTableView is
    /// still delivering the click is a reentrant table update.
    func didSelect(_ key: FileKey?) {
        guard let key else { return }
        changedSinceViewed.remove(key)
        ensureLoaded(key)
    }

    func moveFile(_ delta: Int) {
        let files = allFiles
        guard !files.isEmpty else { return }
        let current = files.firstIndex { $0.key == selection } ?? (delta > 0 ? -1 : files.count)
        select(files[max(0, min(files.count - 1, current + delta))].key)
    }

    // MARK: Viewed

    func isViewed(_ key: FileKey) -> Bool { viewed[key] != nil }

    func setViewed(_ key: FileKey, _ value: Bool) {
        changedSinceViewed.remove(key)
        guard value else {
            viewed[key] = nil
            scheduleDraftSave()
            return
        }
        viewed[key] = ViewedTracker.unknown
        scheduleDraftSave()
        guard let file = file(key), let mergeBase = repo(key)?.base.mergeBase else { return }
        Task {
            guard let fingerprint = await ViewedTracker.fingerprint(of: file, mergeBase: mergeBase) else { return }
            if viewed[key] == ViewedTracker.unknown {
                viewed[key] = fingerprint
                scheduleDraftSave()
            }
        }
    }

    func toggleViewedAndAdvance() {
        guard let key = selection else { return }
        let nowViewed = !isViewed(key)
        setViewed(key, nowViewed)
        if nowViewed { moveFile(1) }
    }

    // MARK: Diff loading

    func diffState(_ key: FileKey) -> DiffState? { diffStates[key] }

    /// Loads the diff for `key`. `keepCurrent` leaves what is on screen in place until the new diff
    /// arrives (used by refresh, so the view doesn't flash or lose its scroll position).
    func ensureLoaded(_ key: FileKey, force: Bool = false, keepCurrent: Bool = false) {
        let wasStale = staleKeys.remove(key) != nil
        if !force, !keepCurrent, !wasStale, diffStates[key] != nil { return }
        guard let file = file(key), let repo = repo(key) else { return }
        if force { forcedLoads.insert(key) }
        let effectiveForce = force || forcedLoads.contains(key)
        if !(keepCurrent || wasStale) || diffStates[key] == nil { diffStates[key] = .loading }
        let mergeBase = repo.base.mergeBase
        let token = loadGate.begin(key)
        Task {
            let state: DiffState
            do {
                switch try await DiffLoader.load(file, mergeBase: mergeBase, force: effectiveForce) {
                case let .diff(diff): state = .ready(makeLoadedFile(diff, key))
                case let .binary(info): state = .binary(info)
                case let .tooLarge(reason): state = .tooLarge(reason)
                case .generated: state = .generated
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
            // A refresh or a newer load for this file supersedes this one.
            guard loadGate.isCurrent(key, token: token) else { return }
            // An identical diff keeps the existing LoadedFile, so its cached rows and the view stay put.
            if case let .ready(new) = state, case let .ready(old)? = diffStates[key], old.diff == new.diff { return }
            // A different diff renumbers everything: expanded runs, removed-block ids and the change
            // cursor are indexes into the old one and would now point at the wrong lines.
            if case .ready = state { resetPositionState(for: key) }
            diffStates[key] = state
        }
    }

    private func makeLoadedFile(_ diff: FileDiff, _ key: FileKey) -> LoadedFile {
        let loaded = LoadedFile(diff: diff)
        loaded.onStyleChange = { [weak self] in self?.styleVersions[key, default: 0] += 1 }
        loaded.startHighlighting()
        return loaded
    }

    func styleVersion(_ key: FileKey) -> Int { styleVersions[key] ?? 0 }

    /// Forgets view state that is keyed by diff-line indexes. (`expandedAll` is index-free and stays.)
    private func resetPositionState(for key: FileKey) {
        expandedRuns[key] = nil
        changeCursor[key] = nil
        for block in removedOverride.keys where block.file == key { removedOverride[block] = nil }
    }

    func loadedFile(_ key: FileKey) -> LoadedFile? {
        if case let .ready(loaded) = diffStates[key] { return loaded }
        return nil
    }

    // MARK: Expansion

    func expandRun(_ key: FileKey, runStart: Int) { expandedRuns[key, default: []].insert(runStart) }
    func expandAll(_ key: FileKey) { expandedAll.insert(key) }
    func isExpandedAll(_ key: FileKey) -> Bool { expandedAll.contains(key) }
    func expandedRuns(_ key: FileKey) -> Set<Int> { expandedRuns[key] ?? [] }

    /// A removed block is shown when the user opened it, or (unless they closed it) when it holds a
    /// commented line or the open editor, so comments never hide inside a collapsed block.
    func isRemovedExpanded(_ block: RemovedBlockKey, oldLines: [Int]) -> Bool {
        if let choice = removedOverride[block] { return choice }
        return oldLines.contains { number in
            byLine[LineSlot(file: block.file, side: .old, line: number)] != nil
                || (editor.map { $0.anchor.fileKey == block.file && $0.anchor.side == .old && $0.anchor.endLine == number } ?? false)
        }
    }

    func toggleRemoved(_ block: RemovedBlockKey, oldLines: [Int]) {
        removedOverride[block] = !isRemovedExpanded(block, oldLines: oldLines)
    }

    /// Diff-line indexes of commented lines, kept visible when unchanged runs collapse.
    func pinnedLines(_ key: FileKey, in loaded: LoadedFile) -> Set<Int> {
        var pinned = Set<Int>()
        for comment in byFile[key] ?? [] {
            guard let start = comment.anchor.startLine else { continue }
            for line in [start, comment.anchor.endLine ?? start] {
                if let i = loaded.diff.lineIndex(side: comment.anchor.side, number: line) { pinned.insert(i) }
            }
        }
        return pinned
    }

    // MARK: Font

    func adjustFont(_ delta: CGFloat) { fontSize = max(9, min(28, fontSize + delta)) }
    func resetFont() { fontSize = 12 }

    // MARK: Navigation

    func moveChange(_ delta: Int) {
        guard let key = selection, let loaded = loadedFile(key) else { return }
        let starts: [Int]
        switch mode {
        case .changes:
            starts = loaded.changeStarts(in: loaded.sideRows(
                expandedRuns: expandedRuns(key), expandAll: isExpandedAll(key), pinned: pinnedLines(key, in: loaded)))
        case .file:
            starts = loaded.fileChangeStarts
        }
        guard !starts.isEmpty else { return }
        let cursor = max(-1, min(starts.count, (changeCursor[key] ?? -1) + delta))
        let next = max(0, min(starts.count - 1, cursor))
        changeCursor[key] = next
        scrollRequest = ScrollRequest(file: key, target: .row(starts[next]))
    }

    func jump(to comment: Comment) {
        let anchor = comment.anchor
        select(anchor.fileKey)
        showFinish = false
        guard let line = anchor.startLine else { return }
        if anchor.side == .old { mode = .changes }
        scrollRequest = ScrollRequest(file: anchor.fileKey, target: .line(side: anchor.side, number: line))
    }

    // MARK: Comments

    func comments(at slot: LineSlot) -> [Comment] { byLine[slot] ?? [] }
    func fileComments(_ key: FileKey) -> [Comment] { (byFile[key] ?? []).filter { $0.anchor.isFileLevel } }
    func commentCount(_ key: FileKey) -> Int { byFile[key]?.count ?? 0 }

    func isOutdated(_ comment: Comment) -> Bool {
        guard case let .ready(loaded) = diffStates[comment.anchor.fileKey] else { return false }
        return comment.isOutdated(in: loaded.diff)
    }

    func hasThread(_ slot: LineSlot) -> Bool {
        if byLine[slot] != nil { return true }
        guard let a = editor?.anchor else { return false }
        return a.fileKey == slot.file && a.side == slot.side && a.endLine == slot.line
    }

    func editorState(for slot: LineSlot) -> EditorState? {
        guard let editor, editor.anchor.fileKey == slot.file, editor.anchor.side == slot.side,
              editor.anchor.endLine == slot.line else { return nil }
        return editor
    }

    /// Opens the inline editor under `line`. With `extend`, grows the open editor's range to include it.
    func beginComment(file key: FileKey, side requestedSide: Side, line requestedLine: Int, extend: Bool) {
        guard let loaded = loadedFile(key) else { return }
        let (side, line) = loaded.diff.canonicalAnchor(side: requestedSide, line: requestedLine)
        var start = line, end = line
        var keepText = false
        if extend, let open = editor, open.editing == nil, open.anchor.fileKey == key, open.anchor.side == side,
           let s = open.anchor.startLine, let e = open.anchor.endLine {
            start = min(s, line)
            end = max(e, line)
            keepText = true
        }
        let snapshot = loaded.diff.text(side: side, from: start, to: end) ?? ""
        if !keepText { editorText = "" }
        editor = EditorState(anchor: Anchor(repoRoot: key.repoRoot, path: key.path, side: side, startLine: start, endLine: end, lineText: snapshot))
    }

    func beginFileComment(_ key: FileKey) {
        editorText = ""
        editor = EditorState(anchor: Anchor(repoRoot: key.repoRoot, path: key.path))
    }

    func beginEdit(_ comment: Comment) {
        editorText = comment.body
        editor = EditorState(anchor: comment.anchor, editing: comment.id)
    }

    func cancelEditor() {
        editor = nil
        editorText = ""
    }

    func saveEditor() {
        guard let editor else { return }
        let body = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if let id = editor.editing, let i = comments.firstIndex(where: { $0.id == id }) {
            comments[i].body = body
        } else {
            comments.append(Comment(anchor: editor.anchor, body: body))
        }
        cancelEditor()
        commentsChanged()
    }

    /// Turns a half-typed comment into a real one (used before finishing, so it is never lost).
    func commitPendingEditor() {
        if hasPendingEditorText { saveEditor() }
    }

    var hasPendingEditorText: Bool {
        editor != nil && !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func delete(_ comment: Comment) {
        comments.removeAll { $0.id == comment.id }
        if editor?.editing == comment.id { cancelEditor() }
        commentsChanged()
    }

    private func commentsChanged() {
        rebuildCommentIndex()
        scheduleDraftSave()
    }

    private func rebuildCommentIndex() {
        byLine = [:]
        byFile = [:]
        for comment in comments {
            let a = comment.anchor
            byFile[a.fileKey, default: []].append(comment)
            if let end = a.endLine { byLine[LineSlot(file: a.fileKey, side: a.side, line: end), default: []].append(comment) }
        }
    }

    // MARK: Finishing

    var hasContent: Bool {
        !comments.isEmpty || hasPendingEditorText || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shows the finish sheet, first committing any comment that is still being typed.
    func openFinish() {
        commitPendingEditor()
        showFinish = true
    }

    var effectiveVerdict: Verdict { chosenVerdict ?? (comments.isEmpty ? .approve : .requestChanges) }

    private var roots: [String] { repos.map(\.context.root) }

    /// Loads the diff of every commented file so outdated comments can be flagged in the output.
    private func makeSubmission() async -> ReviewSubmission {
        var outdated = Set<UUID>()
        var diffs: [FileKey: FileDiff] = [:]
        for key in Set(comments.filter { !$0.anchor.isFileLevel }.map { $0.anchor.fileKey }) {
            guard let file = file(key), let repo = repo(key),
                  case let .diff(diff)? = try? await DiffLoader.load(file, mergeBase: repo.base.mergeBase, force: true) else { continue }
            diffs[key] = diff
        }
        for comment in comments where comment.isOutdated(in: diffs[comment.anchor.fileKey]) { outdated.insert(comment.id) }
        let infos = repos.map {
            ReviewRepoInfo(name: $0.context.displayName, root: $0.context.root, branch: $0.context.branch, base: $0.base.ref, mergeBase: $0.base.mergeBase)
        }
        var oldPaths: [FileKey: String] = [:]
        for key in Set(comments.map(\.anchor.fileKey)) {
            if let old = file(key)?.oldPath { oldPaths[key] = old }
        }
        return ReviewSubmission(
            verdict: effectiveVerdict, summary: summary, repos: infos, comments: comments, outdated: outdated, oldPaths: oldPaths)
    }

    func submit() async -> Never {
        commitPendingEditor()
        let review = await makeSubmission()
        let markdown = ReviewRenderer.markdown(review)
        let json = (try? ReviewRenderer.json(review)) ?? "{}"
        do { try archive.save(markdown: markdown, json: json) } catch {
            Output.warn("could not archive review: \(error.localizedDescription)")
        }
        if let path = options.output {
            do { try Data((options.json ? json : markdown).utf8).write(to: URL(fileURLWithPath: path)) } catch {
                Output.warn("could not write \(path): \(error.localizedDescription)")
            }
        }
        keepViewedForNextRound()
        Output.finish(code: 0, stdout: options.json ? json : markdown)
    }

    func discard() -> Never {
        keepViewedForNextRound()
        Output.finish(code: 2, stderr: "revu: review closed without submitting")
    }

    // MARK: Drafts

    /// After a submit or discard the comments and summary are gone, but the viewed fingerprints stay,
    /// so the next round on the same repos starts with unchanged files still viewed.
    func keepViewedForNextRound() {
        saveTask?.cancel()
        try? drafts.save(ReviewDraft(viewed: viewed), roots: roots)
    }

    func scheduleDraftSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushDraft()
        }
    }

    func flushDraft() {
        saveTask?.cancel()
        try? drafts.save(ReviewDraft(comments: comments, summary: summary, viewed: viewed), roots: roots)
    }
}
