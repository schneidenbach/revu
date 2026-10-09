import Testing
@testable import RevuCore
@testable import revu

// Diff of the fixture file (index: kind old/new):
// 0 ctx one 1/1 | 1 -two 2/- | 2 +TWO -/2 | 3 ctx three 3/3 | 4 -four 4/- | 5 ctx five 5/4 | 6 +six -/5
@MainActor
@Suite struct AppStateTests {
    // MARK: unsent comments are never lost

    @Test func halfTypedCommentCountsAsContent() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        #expect(!f.state.hasContent)
        f.state.beginComment(file: f.key, side: .new, line: 2, extend: false)
        #expect(!f.state.hasContent)                       // an empty editor is not content
        f.state.editorText = "   \n"
        #expect(!f.state.hasContent)
        f.state.editorText = "why?"
        #expect(f.state.hasContent)                        // so closing the window must ask first
    }

    @Test func openFinishCommitsThePendingComment() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginComment(file: f.key, side: .new, line: 2, extend: false)
        f.state.editorText = "  why?  "
        f.state.openFinish()
        #expect(f.state.showFinish)
        #expect(f.state.comments.map(\.body) == ["why?"])
        #expect(f.state.comments[0].anchor.startLine == 2)
        #expect(f.state.editor == nil)
        #expect(f.state.editorText == "")
    }

    @Test func openFinishCommitsAPendingEditAndFileComment() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginFileComment(f.key)
        f.state.editorText = "file note"
        f.state.saveEditor()
        let comment = f.state.comments[0]
        f.state.beginEdit(comment)
        #expect(f.state.editorText == "file note")
        f.state.editorText = "edited"
        f.state.openFinish()
        #expect(f.state.comments.map(\.body) == ["edited"])
        #expect(f.state.comments[0].id == comment.id)
    }

    @Test func openFinishWithAnEmptyEditorAddsNothing() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginComment(file: f.key, side: .new, line: 2, extend: false)
        f.state.openFinish()
        #expect(f.state.showFinish)
        #expect(f.state.comments.isEmpty)
    }

    // MARK: comment anchoring

    @Test func commentOnAContextLineOfTheOldSideAnchorsToTheNewSide() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginComment(file: f.key, side: .old, line: 5, extend: false)   // "five": old 5 == new 4
        let anchor = try #require(f.state.editor?.anchor)
        #expect(anchor.side == .new)
        #expect(anchor.startLine == 4 && anchor.endLine == 4)
        #expect(anchor.lineText == "five")

        f.state.beginComment(file: f.key, side: .old, line: 4, extend: false)   // "four" was really removed
        #expect(f.state.editor?.anchor.side == .old)
        #expect(f.state.editor?.anchor.lineText == "four")
    }

    @Test func rangeExtensionNormalizesToo() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginComment(file: f.key, side: .old, line: 3, extend: false)   // context "three" -> new 3
        f.state.editorText = "keep me"
        f.state.beginComment(file: f.key, side: .old, line: 5, extend: true)    // context "five" -> new 4
        let anchor = try #require(f.state.editor?.anchor)
        #expect(anchor.side == .new)
        #expect((anchor.startLine, anchor.endLine) == (3, 4))
        #expect(anchor.lineText == "three\nfive")
        #expect(f.state.editorText == "keep me")           // extending keeps what was typed
        f.state.beginComment(file: f.key, side: .new, line: 1, extend: false)
        #expect(f.state.editorText == "")                  // a fresh editor starts empty
    }

    // MARK: removed blocks in the file view

    @Test func removedBlockOpensWhenItHoldsACommentUnlessTheUserClosesIt() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        let block = RemovedBlockKey(file: f.key, id: -5)   // the block holding old line 4
        #expect(!f.state.isRemovedExpanded(block, oldLines: [4]))

        f.state.beginComment(file: f.key, side: .old, line: 4, extend: false)
        #expect(f.state.isRemovedExpanded(block, oldLines: [4]))   // the open editor keeps it visible
        f.state.editorText = "why remove?"
        f.state.saveEditor()
        #expect(f.state.isRemovedExpanded(block, oldLines: [4]))   // so does a saved comment
        #expect(!f.state.isRemovedExpanded(block, oldLines: [2]))  // other blocks are unaffected

        f.state.toggleRemoved(block, oldLines: [4])                // the user can still close it
        #expect(!f.state.isRemovedExpanded(block, oldLines: [4]))
        f.state.toggleRemoved(block, oldLines: [4])
        #expect(f.state.isRemovedExpanded(block, oldLines: [4]))
    }

    // MARK: refresh

    @Test func refreshReplacesTheCachedDiff() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        #expect(f.state.loadedFile(f.key)?.diff.lines.contains { $0.text == "six" } == true)

        f.repo.write("a.txt", "one\nTWO\nthree\nfive\nseven\n")
        f.state.refresh()
        for _ in 0..<200 {
            if let loaded = f.state.loadedFile(f.key), loaded.diff.lines.contains(where: { $0.text == "seven" }) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let texts = f.state.loadedFile(f.key)?.diff.lines.map(\.text) ?? []
        #expect(texts.contains("seven"))
        #expect(!texts.contains("six"))
    }

    // MARK: in-place refresh and Viewed fingerprints

    private func waitForFingerprint(_ f: Fixture) async throws {
        for _ in 0..<200 {
            if let value = f.state.viewed[f.key], value != ViewedTracker.unknown { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw RevuError("fingerprint was not computed")
    }

    @Test func markingViewedStoresAFingerprint() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.setViewed(f.key, true)
        #expect(f.state.isViewed(f.key))
        try await waitForFingerprint(f)
        f.state.setViewed(f.key, false)
        #expect(!f.state.isViewed(f.key))
    }

    @Test func editingAViewedFileUnchecksItAndMarksItChangedUntilSelected() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.repo.write("other.txt", "side\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: false)
        let other = FileKey(repoRoot: f.repo.path, path: "other.txt")
        f.state.select(other)
        f.state.setViewed(f.key, true)
        try await waitForFingerprint(f)

        // Touching without a content change keeps it viewed.
        f.repo.write("a.txt", "one\nTWO\nthree\nfive\nsix\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: false)
        #expect(f.state.isViewed(f.key))
        #expect(f.state.changedSinceViewed.isEmpty)

        f.repo.write("a.txt", "one\nTWO\nthree\nfive\nsix\nseven\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: true)
        #expect(!f.state.isViewed(f.key))
        #expect(f.state.changedSinceViewed == [f.key])
        #expect(f.state.showUpdatedToast)          // automatic refreshes announce themselves

        // The sidebar List only writes `selection`; its onChange then calls didSelect.
        f.state.selection = f.key
        #expect(f.state.changedSinceViewed == [f.key])   // nothing else changes inside the table's binding
        f.state.didSelect(f.key)
        #expect(f.state.changedSinceViewed.isEmpty)
    }

    @Test func legacyDraftViewedMarksKeepViewedAndGetFingerprints() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["a.txt": "1\n"])
        repo.write("a.txt", "2\n")
        let key = FileKey(repoRoot: repo.path, path: "a.txt")
        let drafts = DraftStore(directory: tmp.url.appendingPathComponent("drafts"))
        try tmp.write("drafts/\(DraftStore.key(for: [repo.path])).json",
                      "{\"comments\":[],\"summary\":\"\",\"viewed\":[{\"repoRoot\":\"\(repo.path)\",\"path\":\"a.txt\"}]}")
        let snapshots = try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: repo.path)], globalBase: "HEAD")
        let state = AppState(snapshots: snapshots, options: Options(targets: [RepoTarget(directory: repo.path)]),
                             drafts: drafts, archive: ReviewArchive(directory: tmp.url.appendingPathComponent("r")))
        #expect(state.isViewed(key))
        for _ in 0..<200 where state.viewed[key] == ViewedTracker.unknown { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(state.viewed[key] != ViewedTracker.unknown)
        #expect(state.changedSinceViewed.isEmpty)
    }

    @Test func refreshKeepsSelectionCommentsAndTheCachedDiffWhenNothingChanged() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginComment(file: f.key, side: .new, line: 2, extend: false)
        f.state.editorText = "keep"
        f.state.saveEditor()
        f.state.mode = .file
        let before = try #require(f.state.loadedFile(f.key))

        f.repo.write("unrelated.txt", "new file\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: true)
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 25_000_000) }

        #expect(f.state.selection == f.key)
        #expect(f.state.mode == .file)
        #expect(f.state.comments.map(\.body) == ["keep"])
        #expect(f.state.allFiles.map(\.path) == ["a.txt", "unrelated.txt"])
        #expect(f.state.loadedFile(f.key) === before)       // identical diff: same object, no flash
    }

    @Test func filesThatNoLongerDifferDisappearButTheirCommentsStay() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginComment(file: f.key, side: .new, line: 2, extend: false)
        f.state.editorText = "stale soon"
        f.state.saveEditor()

        f.repo.write("a.txt", "one\ntwo\nthree\nfour\nfive\n")      // back to the base content
        await f.state.performRefresh(roots: [f.repo.path], automatic: true)
        #expect(f.state.allFiles.isEmpty)
        #expect(f.state.selection == nil)
        #expect(f.state.comments.count == 1)
        #expect(f.state.commentCount(f.key) == 1)
    }

    @Test func refreshShowsTheNewDiffOfTheSelectedFile() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.repo.write("a.txt", "one\nTWO\nthree\nfive\nseven\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: false)
        for _ in 0..<200 where f.state.loadedFile(f.key)?.diff.lines.contains(where: { $0.text == "seven" }) != true {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let texts = f.state.loadedFile(f.key)?.diff.lines.map(\.text) ?? []
        #expect(texts.contains("seven") && !texts.contains("six"))
    }

    // MARK: precomputed highlighting

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @Test func styledStringsAreBuiltAheadOfTimeAndOnlyLookedUpByViews() async throws {
        let f = try await Fixture.make(
            path: "Service.cs", base: "public class A\n{\n    int x = 1;\n}\n", work: "public class A\n{\n    int x = 2;\n    string s = \"a\";\n}\n")
        defer { f.tmp.cleanup() }
        let loaded = try #require(f.state.loadedFile(f.key))
        #expect(loaded.language == .csharp)

        let rows = loaded.sideRows(expandedRuns: [], expandAll: false, pinned: [])
        var requests: [(cell: SideCell, column: LoadedFile.Column)] = []
        for row in rows { if case let .pair(l, r) = row.content { requests += [(l, .left), (r, .right)] } }
        loaded.want(requests)
        try await waitFor { requests.allSatisfy { $0.cell.kind == .filler || $0.cell.text.isEmpty || loaded.styled($0.cell, $0.column) != nil || $0.cell.text == "{" || $0.cell.text == "}" } }

        // `public class A` is lexed (keywords), on both sides.
        let publicCell = try #require(requests.first { $0.cell.text == "public class A" && $0.column == .right }).cell
        let styled = try #require(loaded.styled(publicCell, .right))
        #expect(String(styled.characters) == "public class A")
        #expect(styled.runs.count > 1)                                  // keyword and plain runs
        // Punctuation-only lines have no tokens and stay plain (nil), not an empty attributed string.
        let brace = try #require(requests.first { $0.cell.text == "{" }).cell
        #expect(loaded.styled(brace, .right) == nil)
        // A word-diff pair carries both syntax colours and the changed-range background.
        let changed = try #require(requests.first { $0.cell.text == "    int x = 2;" && $0.column == .right }).cell
        #expect(!changed.changedRanges.isEmpty)
        let changedStyled = try #require(loaded.styled(changed, .right))
        #expect(changedStyled.runs.count >= 3)
    }

    @Test func unknownLanguagesStillGetWordDiffBackgroundsButNoSyntaxColours() async throws {
        let f = try await Fixture.make(path: "notes.xyz", base: "let value = foo(1)\n", work: "let value = bar(1)\n")
        defer { f.tmp.cleanup() }
        let loaded = try #require(f.state.loadedFile(f.key))
        #expect(loaded.language == nil)
        let rows = loaded.sideRows(expandedRuns: [], expandAll: false, pinned: [])
        guard case let .pair(left, right) = rows[0].content else { Issue.record("expected a pair"); return }
        loaded.want([(left, .left), (right, .right)])
        try await waitFor { loaded.styled(right, .right) != nil }
        let styled = try #require(loaded.styled(right, .right))
        #expect(styled.runs.count == 3)                                  // plain, changed word, plain
    }

    @Test func stylingNotifiesTheViewsThroughTheVersionCounter() async throws {
        let f = try await Fixture.make(path: "a.json", base: "{\"a\": 1}\n", work: "{\"a\": 2}\n")
        defer { f.tmp.cleanup() }
        let loaded = try #require(f.state.loadedFile(f.key))
        let before = f.state.styleVersion(f.key)
        let rows = loaded.sideRows(expandedRuns: [], expandAll: false, pinned: [])
        guard case let .pair(_, right) = rows[0].content else { Issue.record("expected a pair"); return }
        loaded.want([(right, .right)])
        try await waitFor { f.state.styleVersion(f.key) > before }
        #expect(f.state.styleVersion(f.key) > before)
        #expect(loaded.styled(right, .right) != nil)
    }

    // MARK: per-file view state is tied to the diff it was created for

    private static let thirty = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
    private static func thirtyEditing(_ edits: [Int: String]) -> String {
        (1...30).map { edits[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test func positionStateSurvivesAnIdenticalDiffButNotADifferentOne() async throws {
        let f = try await Fixture.make(path: "big.txt", base: Self.thirty, work: Self.thirtyEditing([15: "CHANGED"]))
        defer { f.tmp.cleanup() }
        let block = RemovedBlockKey(file: f.key, id: -15)
        f.state.expandRun(f.key, runStart: 0)
        f.state.expandAll(f.key)
        f.state.toggleRemoved(block, oldLines: [15])
        f.state.moveChange(1)
        #expect(f.state.expandedRuns(f.key) == [0])
        #expect(f.state.isRemovedExpanded(block, oldLines: []))
        #expect(f.state.changeCursor[f.key] == 0)

        // A refresh that leaves this file's diff alone keeps everything.
        f.repo.write("other.txt", "x\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: true)
        _ = try await eventually(seconds: 0.5) { false }
        #expect(f.state.expandedRuns(f.key) == [0])
        #expect(f.state.isRemovedExpanded(block, oldLines: []))
        #expect(f.state.changeCursor[f.key] == 0)

        // A different diff renumbers the lines, so index-keyed state is dropped; expandedAll is index-free.
        let before = try #require(f.state.loadedFile(f.key))
        f.repo.write("big.txt", Self.thirtyEditing([3: "EARLY", 15: "CHANGED"]))
        await f.state.performRefresh(roots: [f.repo.path], automatic: true)
        #expect(try await eventually { f.state.loadedFile(f.key).map { $0 !== before } == true })
        #expect(f.state.expandedRuns(f.key).isEmpty)
        #expect(!f.state.isRemovedExpanded(block, oldLines: []))
        #expect(f.state.changeCursor[f.key] == nil)
        #expect(f.state.isExpandedAll(f.key))
    }

    @Test func otherFilesKeepTheirExpansionWhenTheirDiffDidNotChange() async throws {
        let f = try await Fixture.make(path: "big.txt", base: Self.thirty, work: Self.thirtyEditing([15: "CHANGED"]))
        defer { f.tmp.cleanup() }
        f.repo.write("zzz.txt", "z\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: false)
        let big = f.key
        let zzz = FileKey(repoRoot: f.repo.path, path: "zzz.txt")
        f.state.expandRun(big, runStart: 0)
        f.state.select(zzz)
        await f.state.performRefresh(roots: [f.repo.path], automatic: false)   // big.txt is now a background file
        f.state.select(big)
        _ = try await eventually(seconds: 0.5) { false }
        #expect(f.state.expandedRuns(big) == [0])
        #expect(f.state.loadedFile(big) != nil)
    }

    // MARK: viewed marks survive a review round

    @Test func viewedMarksSurviveSubmitAndRelaunchForUnchangedFiles() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.beginComment(file: f.key, side: .new, line: 2, extend: false)
        f.state.editorText = "fix this"
        f.state.saveEditor()
        f.state.summary = "round one"
        f.state.setViewed(f.key, true)
        #expect(try await eventually { f.state.viewed[f.key].map { $0 != ViewedTracker.unknown } == true })

        f.state.keepViewedForNextRound()               // what submit and discard do before exiting

        let second = try await f.relaunch()
        #expect(second.comments.isEmpty)
        #expect(second.summary.isEmpty)
        #expect(second.restoredCount == nil)           // no "Restored N draft comments" banner
        _ = try await eventually(seconds: 1) { false } // let the recheck finish
        #expect(second.isViewed(f.key))
        #expect(second.changedSinceViewed.isEmpty)
    }

    @Test func aFileEditedBetweenRoundsComesBackUnviewedAndFlagged() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.repo.write("other.txt", "keep\n")
        await f.state.performRefresh(roots: [f.repo.path], automatic: false)
        let other = FileKey(repoRoot: f.repo.path, path: "other.txt")
        f.state.setViewed(f.key, true)
        f.state.setViewed(other, true)
        #expect(try await eventually { [f.key, other].allSatisfy { f.state.viewed[$0].map { $0 != ViewedTracker.unknown } == true } })
        f.state.keepViewedForNextRound()

        f.repo.write("a.txt", "one\nTWO\nthree\nfive\nsix\nand the agent's fix\n")
        let second = try await f.relaunch()
        #expect(try await eventually { !second.isViewed(f.key) })
        #expect(second.changedSinceViewed == [f.key])
        #expect(second.isViewed(other))                // untouched file stays viewed
    }

    @Test func aViewedOnlyDraftIsKeptButAnEmptyOneIsNot() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        f.state.keepViewedForNextRound()               // nothing viewed: no file left behind
        #expect(DraftStore(directory: f.tmp.url.appendingPathComponent("drafts")).load(roots: [f.repo.path]) == nil)
        f.state.setViewed(f.key, true)
        f.state.keepViewedForNextRound()
        let draft = try #require(DraftStore(directory: f.tmp.url.appendingPathComponent("drafts")).load(roots: [f.repo.path]))
        #expect(draft.comments.isEmpty && draft.summary.isEmpty)
        #expect(draft.viewed.keys.contains(f.key))
    }

    // MARK: failed automatic refreshes retry, then give up

    @Test func performRefreshReportsFailure() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        try f.breakRepo()
        let failed = await f.state.performRefresh(roots: [f.repo.path], automatic: true)
        #expect(!failed)
        #expect(f.state.lastError != nil)
        try f.repairRepo()
        let ok = await f.state.performRefresh(roots: [f.repo.path], automatic: true)
        #expect(ok)
        #expect(f.state.lastError == nil)
    }

    @Test func aFailedAutomaticRefreshIsRetriedUntilItSucceeds() async throws {
        let f = try await Fixture.make(refreshDelay: 0.02, retryDelay: 0.05); defer { f.tmp.cleanup() }
        try f.breakRepo()
        f.state.externalChange(in: f.repo.path)
        #expect(try await eventually { f.state.refreshAttempts >= 1 && f.state.lastError != nil })

        // The agent finishes what it was doing; no further file event arrives.
        f.repo.write("later.txt", "new\n")
        try f.repairRepo()
        #expect(try await eventually { f.state.allFiles.map(\.path).contains("later.txt") })
        #expect(f.state.lastError == nil)
    }

    @Test func retriesStopAfterThreeFailuresAndANewEventStartsOver() async throws {
        let f = try await Fixture.make(refreshDelay: 0.02, retryDelay: 0.05); defer { f.tmp.cleanup() }
        try f.breakRepo()
        f.state.externalChange(in: f.repo.path)
        #expect(try await eventually { f.state.refreshAttempts == 3 })
        _ = try await eventually(seconds: 0.5) { false }     // time for a (wrong) fourth attempt
        #expect(f.state.refreshAttempts == 3)
        #expect(f.state.lastError != nil)                    // the banner stays up

        try f.repairRepo()
        f.state.externalChange(in: f.repo.path)
        #expect(try await eventually { f.state.refreshAttempts == 4 && f.state.lastError == nil })
    }

    // MARK: open in editor

    private final class Calls { var urls: [String] = []; var alerts: [(String, String)] = [] }

    private func wire(_ state: AppState, opens: Bool) -> Calls {
        let calls = Calls()
        state.openURL = { calls.urls.append($0.absoluteString); return opens }
        state.presentEditorMissing = { calls.alerts.append(($0, $1)) }
        return calls
    }

    @Test func openingTheSelectedFileUsesTheEditorUrlAtTheHoveredLine() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        let calls = wire(f.state, opens: true)
        f.state.openSelectedInEditor()                                   // nothing hovered yet: line 1
        let path = f.repo.path + "/a.txt"
        #expect(calls.urls == ["vscode://file" + path + ":1:1"])

        let loaded = try #require(f.state.loadedFile(f.key))
        let rows = loaded.sideRows(expandedRuns: [], expandAll: false, pinned: [])
        guard case let .pair(_, right) = rows[1].content else { Issue.record("expected a pair"); return }
        f.state.noteHover(right, in: f.key)                              // hover "TWO", new line 2
        f.state.openSelectedInEditor()
        #expect(calls.urls.last == "vscode://file" + path + ":2:1")
        #expect(calls.alerts.isEmpty)
    }

    @Test func aRemovedLineOpensWhereItWasRemoved() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        let calls = wire(f.state, opens: true)
        let loaded = try #require(f.state.loadedFile(f.key))
        // diff index 4 is `-four`; the next surviving line is `five`, which is new line 4.
        let removed = SideCell(kind: .removed, number: 4, text: "four", changedRanges: [], diffIndex: 4)
        #expect(f.state.editorLine(for: removed, in: f.key) == 4)
        #expect(f.state.openInEditor(f.key, line: f.state.editorLine(for: removed, in: f.key)))
        #expect(calls.urls.last?.hasSuffix("/a.txt:4:1") == true)
        _ = loaded
    }

    @Test func aMissingEditorShowsAnAlertNamingIt() async throws {
        let f = try await Fixture.make(); defer { f.tmp.cleanup() }
        let calls = wire(f.state, opens: false)
        #expect(!f.state.openInEditor(f.key, line: 3))
        #expect(calls.alerts.count == 1)
        #expect(calls.alerts[0].0.contains("VS Code"))
        #expect(calls.alerts[0].1.contains("REVU_EDITOR"))
        #expect(calls.alerts[0].1.contains("vscode://"))
    }

    @Test func deletedFilesAreNotOpenable() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["gone.txt": "a\n"])
        repo.remove("gone.txt")
        let snapshots = try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: repo.path)], globalBase: "HEAD")
        let state = AppState(snapshots: snapshots, options: Options(targets: [RepoTarget(directory: repo.path)]),
                             drafts: DraftStore(directory: tmp.url.appendingPathComponent("d")),
                             archive: ReviewArchive(directory: tmp.url.appendingPathComponent("r")))
        let calls = wire(state, opens: true)
        let key = FileKey(repoRoot: repo.path, path: "gone.txt")
        #expect(!state.canOpenInEditor(key))
        #expect(!state.openInEditor(key, line: 1))
        state.openSelectedInEditor()
        #expect(calls.urls.isEmpty)
    }

    @Test func theChosenEditorDecidesTheSchemeAndTheLabel() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["a.txt": "a\n"])
        repo.write("a.txt", "b\n")
        let snapshots = try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: repo.path)], globalBase: "HEAD")
        let state = AppState(snapshots: snapshots, options: Options(targets: [RepoTarget(directory: repo.path)]),
                             drafts: DraftStore(directory: tmp.url.appendingPathComponent("d")),
                             archive: ReviewArchive(directory: tmp.url.appendingPathComponent("r")), externalEditor: .zed)
        let calls = wire(state, opens: true)
        #expect(state.externalEditor.name == "Zed")
        state.openInEditor(FileKey(repoRoot: repo.path, path: "a.txt"), line: 5)
        #expect(calls.urls == ["zed://file" + repo.path + "/a.txt:5:1"])
    }
}
