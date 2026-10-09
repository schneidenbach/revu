import Testing
@testable import RevuCore

@Suite struct UnifiedDiffParserTests {
    @Test func modifiedFileWithSeveralHunks() {
        let text = joinLines(
            "diff --git a/f.txt b/f.txt", "index 111..222 100644", "--- a/f.txt", "+++ b/f.txt",
            "@@ -1,3 +1,3 @@", " a", "-b", "+B", " c",
            "@@ -10,3 +10,4 @@ func thing()", " j", "-k", "+K", "+K2", " l")
        let diff = UnifiedDiffParser.parse(text, path: "f.txt")
        #expect(diff.hunkStarts == [0, 4])
        #expect(diff.lines.map(\.kind) == [.context, .removed, .added, .context, .context, .removed, .added, .added, .context])
        #expect(diff.lines[1].oldLine == 2 && diff.lines[1].newLine == nil)
        #expect(diff.lines[2].oldLine == nil && diff.lines[2].newLine == 2)
        #expect(diff.lines[4].oldLine == 10 && diff.lines[4].newLine == 10)
        #expect(diff.lines[7].newLine == 12)
        #expect(diff.lines[8].oldLine == 12 && diff.lines[8].newLine == 13)
        #expect(!diff.isNew && !diff.isDeleted && !diff.isRename && !diff.isBinary)
    }

    @Test func hunkHeaderWithoutCountsMeansOne() {
        let diff = UnifiedDiffParser.parse(joinLines("@@ -1 +1 @@", "-a", "+b"), path: "f")
        #expect(diff.lines.count == 2)
        #expect(diff.lines[0].oldLine == 1)
        #expect(diff.lines[1].newLine == 1)
    }

    @Test func addedFile() {
        let text = joinLines(
            "diff --git a/n.txt b/n.txt", "new file mode 100644", "index 000..abc", "--- /dev/null", "+++ b/n.txt",
            "@@ -0,0 +1,2 @@", "+one", "+two")
        let diff = UnifiedDiffParser.parse(text, path: "n.txt")
        #expect(diff.isNew)
        #expect(diff.newMode == "100644")
        #expect(diff.lines.map(\.text) == ["one", "two"])
        #expect(diff.lines.map(\.newLine) == [1, 2])
        #expect(diff.lines.allSatisfy { $0.oldLine == nil && $0.kind == .added })
    }

    @Test func deletedFile() {
        let text = joinLines(
            "diff --git a/d.txt b/d.txt", "deleted file mode 100644", "index abc..000", "--- a/d.txt", "+++ /dev/null",
            "@@ -1,2 +0,0 @@", "-one", "-two")
        let diff = UnifiedDiffParser.parse(text, path: "d.txt")
        #expect(diff.isDeleted)
        #expect(diff.oldMode == "100644")
        #expect(diff.lines.map(\.oldLine) == [1, 2])
        #expect(diff.lines.allSatisfy { $0.newLine == nil && $0.kind == .removed })
    }

    @Test func pureRenameHasNoHunks() {
        let text = joinLines(
            "diff --git a/old.txt b/new.txt", "similarity index 100%", "rename from old.txt", "rename to new.txt")
        let diff = UnifiedDiffParser.parse(text, path: "new.txt", oldPath: "old.txt")
        #expect(diff.isRename)
        #expect(diff.similarity == 100)
        #expect(diff.oldPath == "old.txt")
        #expect(diff.lines.isEmpty)
        #expect(diff.hunkStarts.isEmpty)
    }

    @Test func renameWithEdits() {
        let text = joinLines(
            "diff --git a/old.txt b/new.txt", "similarity index 83%", "rename from old.txt", "rename to new.txt",
            "index 1..2 100644", "--- a/old.txt", "+++ b/new.txt", "@@ -1,2 +1,2 @@", " keep", "-x", "+y")
        let diff = UnifiedDiffParser.parse(text, path: "new.txt", oldPath: "old.txt")
        #expect(diff.isRename)
        #expect(diff.similarity == 83)
        #expect(diff.lines.count == 3)
    }

    @Test func modeChangeOnly() {
        let diff = UnifiedDiffParser.parse(joinLines("diff --git a/s.sh b/s.sh", "old mode 100644", "new mode 100755"), path: "s.sh")
        #expect(diff.oldMode == "100644")
        #expect(diff.newMode == "100755")
        #expect(diff.lines.isEmpty)
    }

    @Test func binaryFile() {
        let diff = UnifiedDiffParser.parse(
            joinLines("diff --git a/i.png b/i.png", "index 1..2 100644", "Binary files a/i.png and b/i.png differ"), path: "i.png")
        #expect(diff.isBinary)
        #expect(diff.lines.isEmpty)
    }

    @Test func missingNewlineOnOldSide() {
        let diff = UnifiedDiffParser.parse(
            joinLines("@@ -1,2 +1,2 @@", " a", "-b", "\\ No newline at end of file", "+b"), path: "f")
        #expect(diff.lines.map(\.missingNewline) == [false, true, false])
        #expect(diff.lines.count == 3)
    }

    @Test func missingNewlineOnNewSide() {
        let diff = UnifiedDiffParser.parse(
            joinLines("@@ -1,2 +1,2 @@", " a", "-b", "+b", "\\ No newline at end of file"), path: "f")
        #expect(diff.lines.map(\.missingNewline) == [false, false, true])
    }

    @Test func missingNewlineOnContextLineAfterHunkEnd() {
        // The marker follows the last line even though the hunk's counts are already exhausted.
        let diff = UnifiedDiffParser.parse(
            joinLines("@@ -1,2 +1,2 @@", "-a", "+A", " b", "\\ No newline at end of file"), path: "f")
        #expect(diff.lines.map(\.missingNewline) == [false, false, true])
    }

    @Test func crlfContentIsStrippedAndLinesStaySeparate() {
        let text = "@@ -1,3 +1,3 @@\n a\r\n-b\r\n+B\r\n c\r\n"
        let diff = UnifiedDiffParser.parse(text, path: "f")
        #expect(diff.lines.map(\.text) == ["a", "b", "B", "c"])
        #expect(diff.lines.map(\.kind) == [.context, .removed, .added, .context])
    }

    @Test func emptyInputAndEmptyNewFile() {
        let nothing = UnifiedDiffParser.parse("", path: "e.txt")
        #expect(nothing.lines.isEmpty)
        let empty = UnifiedDiffParser.parse(
            joinLines("diff --git a/e.txt b/e.txt", "new file mode 100644", "index 0000000..e69de29"), path: "e.txt")
        #expect(empty.isNew)
        #expect(empty.lines.isEmpty)
    }

    @Test func pathsComeFromCallerNotHeaders() {
        let text = joinLines("diff --git a/my dir/a b.txt b/my dir/a b.txt", "--- a/my dir/a b.txt", "+++ b/my dir/a b.txt", "@@ -1 +1 @@", "-x", "+y")
        let diff = UnifiedDiffParser.parse(text, path: "my dir/a b.txt")
        #expect(diff.path == "my dir/a b.txt")
        #expect(diff.lines.count == 2)
    }

    @Test func contentThatLooksLikeDiffSyntaxIsKeptAsContent() {
        let diff = UnifiedDiffParser.parse(
            joinLines("@@ -1,2 +1,2 @@", "--- not a header", "+++ also not", "@@ -1 +1 @@ nor this"), path: "f")
        // Counts say two old + two new lines: the first two are content ("-- not a header", "++ also not").
        #expect(diff.lines.count >= 2)
        #expect(diff.lines[0].text == "-- not a header")
        #expect(diff.lines[0].kind == .removed)
        #expect(diff.lines[1].text == "++ also not")
        #expect(diff.lines[1].kind == .added)
    }

    @Test func contextLinesOnTheOldSideAnchorToTheNewSide() {
        // old: a b c d   new: a B c d' (lines shift by one after the pure addition)
        let diff = makeDiff("+top", " a", "-b", "+B", " c")
        #expect(diff.canonicalAnchor(side: .old, line: 1) == (.new, 2))   // context "a" moved from old 1 to new 2
        #expect(diff.canonicalAnchor(side: .old, line: 3) == (.new, 4))   // context "c"
        #expect(diff.canonicalAnchor(side: .old, line: 2) == (.old, 2))   // removed "b" stays on the old side
        #expect(diff.canonicalAnchor(side: .new, line: 2) == (.new, 2))   // new side is never rewritten
        #expect(diff.canonicalAnchor(side: .old, line: 99) == (.old, 99)) // unknown lines pass through
    }

    @Test func lineLookupBySide() {
        let diff = makeDiff(" a", "-b", "+B", "+B2", " c")
        #expect(diff.lineIndex(side: .new, number: 2) == 2)
        #expect(diff.lineIndex(side: .old, number: 2) == 1)
        #expect(diff.lineIndex(side: .new, number: 4) == 4)
        #expect(diff.lineIndex(side: .new, number: 9) == nil)
        #expect(diff.text(side: .new, from: 1, to: 3) == "a\nB\nB2")
        #expect(diff.text(side: .old, from: 1, to: 3) == "a\nb\nc")
        #expect(diff.text(side: .old, from: 1, to: 9) == nil)
    }
}

@Suite struct SideBySideTests {
    private func pair(_ row: SideBySideRow) -> (SideCell, SideCell)? {
        if case let .pair(l, r) = row.content { return (l, r) }
        return nil
    }

    @Test func pairsRemovedWithAddedAndFillsTheRest() {
        let more = SideBySide.build(diff: makeDiff(" a", "-r1", "-r2", "-r3", "+n1", " z"))
        #expect(more.count == 5)
        let (l2, r2) = pair(more[2])!
        #expect(l2.kind == .removed && l2.text == "r2")
        #expect(r2.kind == .filler && r2.number == nil)
        let (l1, r1) = pair(more[1])!
        #expect(l1.text == "r1" && r1.text == "n1" && r1.kind == .added)

        let fewer = SideBySide.build(diff: makeDiff("-r1", "+n1", "+n2", "+n3"))
        #expect(fewer.count == 3)
        let (l, r) = pair(fewer[2])!
        #expect(l.kind == .filler)
        #expect(r.text == "n3" && r.number == 3)
        #expect(Set(more.map(\.id)).count == more.count)
        #expect(Set(fewer.map(\.id)).count == fewer.count)
    }

    @Test func pureAdditionsAndRemovals() {
        let rows = SideBySide.build(diff: makeDiff(" a", "+x", "+y", " b", "-q", " c"))
        #expect(rows.map(\.isChange) == [false, true, true, false, true, false])
        #expect(pair(rows[1])!.0.kind == .filler)
        #expect(pair(rows[4])!.1.kind == .filler)
        #expect(pair(rows[4])!.0.number == 3)
    }

    @Test func contextRowsShowBothLineNumbers() {
        let rows = SideBySide.build(diff: makeDiff("-a", "+A", " b"))
        let (l, r) = pair(rows[1])!
        #expect(l.kind == .context && r.kind == .context)
        #expect(l.number == 2 && r.number == 2)
        let shifted = SideBySide.build(diff: makeDiff("-a", "-a2", "+A", " b"))
        let (l2, r2) = pair(shifted[2])!
        #expect(l2.number == 3 && r2.number == 2)
    }

    @Test func runsOfEightOrFewerStayExpanded() {
        let context = (1...8).map { " c\($0)" }
        let rows = SideBySide.build(diff: makeDiff(context + ["+new"]))
        #expect(rows.count == 9)
        #expect(!rows.contains { if case .collapsed = $0.content { true } else { false } })
    }

    @Test func longTrailingRunKeepsThreeLinesOfContext() {
        let context = (1...9).map { " c\($0)" }
        let rows = SideBySide.build(diff: makeDiff(["-old", "+new"] + context))
        // change row, 3 context lines, collapsed(6)
        #expect(rows.count == 1 + 3 + 1)
        guard case let .collapsed(hidden, runStart) = rows.last!.content else { Issue.record("expected collapsed row"); return }
        #expect(hidden == 6)
        #expect(runStart == 2)
        #expect(pair(rows[3])!.0.text == "c3")
    }

    @Test func longRunBetweenChangesKeepsContextOnBothSides() {
        let context = (1...20).map { " c\($0)" }
        let rows = SideBySide.build(diff: makeDiff(["+top"] + context + ["+bottom"]))
        // top, 3 ctx, collapsed(14), 3 ctx, bottom
        #expect(rows.count == 1 + 3 + 1 + 3 + 1)
        guard case let .collapsed(hidden, _) = rows[4].content else { Issue.record("expected collapsed row"); return }
        #expect(hidden == 14)
        #expect(pair(rows[5])!.0.text == "c18")
    }

    @Test func leadingRunKeepsOnlyTheLastThree() {
        let context = (1...12).map { " c\($0)" }
        let rows = SideBySide.build(diff: makeDiff(context + ["-gone"]))
        guard case let .collapsed(hidden, runStart) = rows[0].content else { Issue.record("expected collapsed row"); return }
        #expect(hidden == 9)
        #expect(runStart == 0)
        #expect(rows.count == 1 + 3 + 1)
    }

    @Test func expandingARunOrEverythingShowsAllLines() {
        let context = (1...20).map { " c\($0)" }
        let diff = makeDiff(["+top"] + context + ["+bottom"])
        let collapsed = SideBySide.build(diff: diff)
        guard case let .collapsed(_, runStart) = collapsed[4].content else { Issue.record("expected collapsed row"); return }

        let expanded = SideBySide.build(diff: diff, expandedRuns: [runStart])
        #expect(expanded.count == 22)
        #expect(SideBySide.build(diff: diff, expandAll: true).count == 22)
        // Row ids of surviving lines are stable across expansion (scroll position survives).
        #expect(collapsed.first?.id == expanded.first?.id)
        #expect(collapsed.last?.id == expanded.last?.id)
    }

    @Test func pinnedLinesStayVisibleWithContext() {
        let context = (1...30).map { " c\($0)" }
        let diff = makeDiff(["+top"] + context + ["+bottom"])
        let pinnedIndex = 15 // diff-line index of c15
        let rows = SideBySide.build(diff: diff, pinned: [pinnedIndex])
        let visibleTexts = rows.compactMap { pair($0)?.1.text }
        #expect(visibleTexts.contains("c15"))
        #expect(visibleTexts.contains("c12") && visibleTexts.contains("c18"))
        #expect(!visibleTexts.contains("c10"))
        #expect(rows.filter { if case .collapsed = $0.content { true } else { false } }.count == 2)
    }

    @Test func fileWithoutChangesIsNeverCollapsed() {
        let rows = SideBySide.build(diff: makeDiff((1...50).map { " c\($0)" }))
        #expect(rows.count == 50)
    }

    @Test func pairedLinesGetWordHighlightsAndTabsAreExpanded() {
        let rows = SideBySide.build(diff: makeDiff("-let x = foo(1)", "+let x = bar(1)", "-\tindent", "+\tdedent"))
        let (l, r) = pair(rows[0])!
        #expect(l.changedRanges == [8..<11])
        #expect(r.changedRanges == [8..<11])
        let (tl, _) = pair(rows[1])!
        #expect(tl.text == "    indent")
    }
}

@Suite struct FileViewModelTests {
    private func summary(_ lines: [FileViewLine]) -> [String] {
        lines.map {
            switch $0.content {
            case let .line(c): "\(c.kind == .added ? "+" : c.kind == .removed ? "-" : " ")\(c.text)"
            case let .removed(b): "[\(b.lines.map(\.text).joined(separator: ","))]"
            }
        }
    }

    @Test func markerSitsWhereLinesWereRemoved() {
        let lines = FileViewModel.build(diff: makeDiff(" a", "-b", " c"))
        #expect(summary(lines) == [" a", "[b]", " c"])
    }

    @Test func replacementLinesFollowTheMarkerAndAreAdded() {
        let lines = FileViewModel.build(diff: makeDiff(" a", "-b1", "-b2", "+B", " c"))
        #expect(summary(lines) == [" a", "[b1,b2]", "+B", " c"])
        guard case let .removed(block) = lines[1].content else { Issue.record("expected block"); return }
        #expect(block.lines.map(\.number) == [2, 3])
    }

    @Test func markerAtTopOfFile() {
        let lines = FileViewModel.build(diff: makeDiff("-first", " a", " b"))
        #expect(summary(lines) == ["[first]", " a", " b"])
    }

    @Test func markerAtEndOfFile() {
        let lines = FileViewModel.build(diff: makeDiff(" a", " b", "-last"))
        #expect(summary(lines) == [" a", " b", "[last]"])
    }

    @Test func markersGetUniqueStableIds() {
        let lines = FileViewModel.build(diff: makeDiff("-x", " a", "-y", "+Y", " b", "-z"))
        #expect(Set(lines.map(\.id)).count == lines.count)
    }

    @Test func newLinesCarryNewNumbersAndWordRanges() {
        let lines = FileViewModel.build(diff: makeDiff(" a", "-let v = 1", "+let v = 2", "+extra"))
        guard case let .line(replaced) = lines[2].content, case let .line(extra) = lines[3].content else {
            Issue.record("expected lines"); return
        }
        #expect(replaced.number == 2 && replaced.changedRanges == [8..<9])
        #expect(extra.number == 3 && extra.changedRanges.isEmpty)
    }

    @Test func deletedFileShowsOldContentAsRemoved() {
        let diff = UnifiedDiffParser.parse(
            joinLines("deleted file mode 100644", "@@ -1,2 +0,0 @@", "-one", "-two"), path: "d")
        let lines = FileViewModel.build(diff: diff)
        #expect(lines.count == 2)
        guard case let .line(first) = lines[0].content else { Issue.record("expected line"); return }
        #expect(first.kind == .removed && first.number == 1 && first.text == "one")
    }

    @Test func addedFileIsAllAdded() {
        let lines = FileViewModel.build(diff: makeDiff("+a", "+b"))
        #expect(summary(lines) == ["+a", "+b"])
    }
}

@Suite struct WordDiffTests {
    @Test func singleTokenChange() {
        let r = WordDiff.changedRanges(old: "let value = foo(1)", new: "let value = bar(1)")
        #expect(r.old == [12..<15])
        #expect(r.new == [12..<15])
    }

    @Test func insertionOnlyMarksNewSide() {
        let r = WordDiff.changedRanges(old: "call(a)", new: "call(a, b)")
        #expect(r.old.isEmpty)
        #expect(r.new == [6..<9])
    }

    @Test func adjacentChangedTokensMergeButSharedSpacesSeparateThem() {
        let merged = WordDiff.changedRanges(old: "f(a+b)", new: "f(c-d)")
        #expect(merged.old == [2..<5])
        #expect(merged.new == [2..<5])
        let split = WordDiff.changedRanges(old: "x = alpha beta;", new: "x = gamma delta;")
        #expect(split.old == [4..<9, 10..<14])
        #expect(split.new == [4..<9, 10..<15])
    }

    @Test func wholeLineChangeProducesNoRanges() {
        let r = WordDiff.changedRanges(old: "abc def", new: "xyz uvw")
        #expect(r.old.isEmpty && r.new.isEmpty)
    }

    @Test func identicalLinesProduceNoRanges() {
        let r = WordDiff.changedRanges(old: "same", new: "same")
        #expect(r.old.isEmpty && r.new.isEmpty)
    }

    @Test func lengthCapSkipsLongLines() {
        let long = String(repeating: "a", count: 1_001)
        let r = WordDiff.changedRanges(old: "x " + long, new: "y " + long)
        #expect(r.old.isEmpty && r.new.isEmpty)
        let atCap = WordDiff.changedRanges(old: "x " + String(repeating: "a", count: 998), new: "y " + String(repeating: "a", count: 998))
        #expect(atCap.old == [0..<1])
    }

    @Test func rangesAreUTF16Offsets() {
        // "é" and the emoji are 1 and 2 UTF-16 units; the change starts after them.
        let r = WordDiff.changedRanges(old: "é😀 one two", new: "é😀 one six")
        #expect(r.old == [8..<11])
    }

    @Test func tabExpansion() {
        #expect(DisplayText.expandTabs("a\tb") == "a   b")
        #expect(DisplayText.expandTabs("\t\tx") == "        x")
        #expect(DisplayText.expandTabs("plain") == "plain")
    }
}

@Suite struct LargeFileTests {
    @Test func fiveThousandLineFileBuildsBothViewsQuickly() {
        var spec: [String] = []
        for i in 1...5_000 {
            if i % 100 == 0 { spec += ["-let v\(i) = old(\(i))", "+let v\(i) = new(\(i))"] } else { spec.append(" let v\(i) = old(\(i))") }
        }
        let clock = ContinuousClock()
        var rows: [SideBySideRow] = []
        var lines: [FileViewLine] = []
        let elapsed = clock.measure {
            let diff = makeDiff(spec)
            rows = SideBySide.build(diff: diff)
            lines = FileViewModel.build(diff: diff)
        }
        #expect(lines.count > 5_000)
        // 50 change rows, each with 3 lines of context either side, joined by collapsed separators.
        #expect(rows.filter(\.isChange).count == 50)
        #expect(rows.count < 500)
        #expect(elapsed < .seconds(2))
    }
}

@Suite struct GeneratedFilesTests {
    @Test func builtInPatterns() {
        for path in [
            "package-lock.json", "web/yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "Cargo.lock", "Gemfile.lock",
            "ios/Podfile.lock", "composer.lock", "poetry.lock", "go.sum", "src/packages.lock.json", "dist/app.min.js",
            "dist/site.min.css", "dist/app.js.map", "Migrations/20240101_Init.Designer.cs", "Migrations/AppDbContextModelSnapshot.cs",
            "Api/Client.g.cs", "Models/Foo.generated.ts", "x/Thing.GENERATED.cs", "A.DESIGNER.CS",
        ] {
            #expect(GeneratedFiles.matchesBuiltInPattern(path), "\(path) should be generated")
        }
        for path in [
            "src/Designer.cs", "Migrations/20240101_Init.cs", "ModelSnapshotter.cs", "lock.json", "app.js", "notes.md",
            "src/generated/Real.cs", "mapper.cs", "package.json",
        ] {
            #expect(!GeneratedFiles.matchesBuiltInPattern(path), "\(path) should not be generated")
        }
    }

    @Test func parsesCheckAttrOutput() {
        let raw = "a.txt\0linguist-generated\0set\0a.txt\0diff\0unspecified\0"
            + "b.dat\0linguist-generated\0unspecified\0b.dat\0diff\0unset\0"
            + "c.txt\0linguist-generated\0unset\0c.txt\0diff\0unspecified\0"
            + "d.txt\0linguist-generated\0true\0d.txt\0diff\0unspecified\0"
            + "e f.txt\0linguist-generated\0false\0e f.txt\0diff\0text\0"
        let parsed = GeneratedFiles.parseCheckAttr(Data(raw.utf8))
        #expect(parsed["a.txt"] == .init(linguistGenerated: true, diffUnset: false))
        #expect(parsed["b.dat"] == .init(linguistGenerated: nil, diffUnset: true))
        #expect(parsed["c.txt"] == .init(linguistGenerated: false, diffUnset: false))
        #expect(parsed["d.txt"]?.linguistGenerated == true)
        #expect(parsed["e f.txt"] == .init(linguistGenerated: false, diffUnset: false))
        #expect(parsed.count == 5)
    }

    @Test func explicitAttributesBeatBuiltInPatterns() {
        #expect(GeneratedFiles.isGenerated(path: "x.min.js", attributes: .init(linguistGenerated: false, diffUnset: false)) == false)
        #expect(GeneratedFiles.isGenerated(path: "plain.txt", attributes: .init(linguistGenerated: true, diffUnset: false)) == true)
        #expect(GeneratedFiles.isGenerated(path: "plain.txt", attributes: .init(linguistGenerated: nil, diffUnset: true)) == true)
        #expect(GeneratedFiles.isGenerated(path: "go.sum", attributes: .init(linguistGenerated: nil, diffUnset: false)) == true)
        #expect(!GeneratedFiles.isGenerated(path: "plain.txt", attributes: nil))
    }
}

@Suite struct EditorTests {
    @Test func buildsUrlsForEveryEditor() {
        let path = "/Users/me/repo/src/a.cs"
        #expect(Editor.vscode.url(path: path, line: 12).absoluteString == "vscode://file/Users/me/repo/src/a.cs:12:1")
        #expect(Editor.cursor.url(path: path, line: 3).absoluteString == "cursor://file/Users/me/repo/src/a.cs:3:1")
        #expect(Editor.vscodeInsiders.url(path: path, line: 7).absoluteString == "vscode-insiders://file/Users/me/repo/src/a.cs:7:1")
        #expect(Editor.zed.url(path: path, line: 9).absoluteString == "zed://file/Users/me/repo/src/a.cs:9:1")
        #expect(Editor.vscode.url(path: path, line: 4, column: 8).absoluteString == "vscode://file/Users/me/repo/src/a.cs:4:8")
        #expect(Editor.vscode.url(path: path).absoluteString == "vscode://file/Users/me/repo/src/a.cs")
    }

    @Test func percentEncodesThePathButKeepsSlashes() {
        #expect(Editor.vscode.url(path: "/Users/me/My Repo/a b.cs", line: 1).absoluteString
            == "vscode://file/Users/me/My%20Repo/a%20b.cs:1:1")
        #expect(Editor.vscode.url(path: "/tmp/café/ü.txt", line: 2).absoluteString == "vscode://file/tmp/caf%C3%A9/%C3%BC.txt:2:1")
        #expect(Editor.zed.url(path: "/tmp/a#b?c%d:e.txt", line: 5).absoluteString == "zed://file/tmp/a%23b%3Fc%25d%3Ae.txt:5:1")
        #expect(Editor.vscode.url(path: "relative/x.cs", line: 1).absoluteString == "vscode://file/relative/x.cs:1:1")
    }

    @Test func namesAndSchemes() {
        #expect(Editor.allCases.map(\.name) == ["VS Code", "Cursor", "VS Code Insiders", "Zed"])
        #expect(Editor.allCases.map(\.scheme) == ["vscode", "cursor", "vscode-insiders", "zed"])
    }

    @Test func environmentSelectionWithFallback() {
        #expect(Editor.fromEnvironment(nil).editor == .vscode)
        #expect(Editor.fromEnvironment(nil).warning == nil)
        #expect(Editor.fromEnvironment("  ").warning == nil)
        for editor in Editor.allCases {
            let result = Editor.fromEnvironment(editor.rawValue)
            #expect(result.editor == editor && result.warning == nil)
        }
        #expect(Editor.fromEnvironment("Cursor").editor == .cursor)           // case-insensitive
        let unknown = Editor.fromEnvironment("emacs")
        #expect(unknown.editor == .vscode)
        #expect(unknown.warning?.contains("emacs") == true)
        #expect(unknown.warning?.contains("vscode-insiders") == true)
    }
}

@Suite struct EditorLineTests {
    @Test func newAndContextLinesUseTheirNewLineNumbers() {
        let diff = makeDiff(" a", "-b", "+B", " c")
        #expect(diff.editorLine(forDiffIndex: 0) == 1)
        #expect(diff.editorLine(forDiffIndex: 2) == 2)     // added
        #expect(diff.editorLine(forDiffIndex: 3) == 3)     // context
        #expect(diff.editorLine(side: .new, number: 3) == 3)
        #expect(diff.editorLine(side: .old, number: 3) == 3)   // old line 3 is the context line `c`, now new line 3
    }

    @Test func removedLinesMapToWhereTheyWereRemoved() {
        let middle = makeDiff(" a", "-b", " c")
        #expect(middle.editorLine(forDiffIndex: 1) == 2)       // the next surviving line, `c`
        #expect(middle.editorLine(side: .old, number: 2) == 2)

        let top = makeDiff("-x", "-y", " a", " b")
        #expect(top.editorLine(forDiffIndex: 0) == 1)
        #expect(top.editorLine(forDiffIndex: 1) == 1)

        let end = makeDiff(" a", " b", "-z")
        #expect(end.editorLine(forDiffIndex: 2) == 2)          // the last line of the file

        let replaced = makeDiff(" a", "-old", "+new", " c")
        #expect(replaced.editorLine(forDiffIndex: 1) == 2)     // where the replacement now is
    }

    @Test func fullyDeletedFilesHaveNoLine() {
        let deleted = UnifiedDiffParser.parse(joinLines("deleted file mode 100644", "@@ -1,2 +0,0 @@", "-one", "-two"), path: "d")
        #expect(deleted.editorLine(forDiffIndex: 0) == nil)
        #expect(deleted.editorLine(forDiffIndex: 1) == nil)
        #expect(deleted.editorLine(side: .old, number: 1) == nil)
    }

    @Test func outOfRangeIsNil() {
        let diff = makeDiff(" a")
        #expect(diff.editorLine(forDiffIndex: 5) == nil)
        #expect(diff.editorLine(forDiffIndex: -1) == nil)
        #expect(diff.editorLine(side: .new, number: 9) == nil)
    }
}
