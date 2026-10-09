import Testing
@testable import RevuCore

@Suite struct RepoResolverTests {
    @Test func resolvesRootBranchAndName() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp, name: "my repo")
        let sha = repo.commit("one", ["src/a.txt": "a\n"])

        let ctx = try await RepoResolver.resolve(directory: repo.path + "/src")
        #expect(ctx.root == repo.path)
        #expect(ctx.branch == "main")
        #expect(ctx.headSHA == sha)
        #expect(ctx.displayName == "my repo")
        #expect(!ctx.isWorktree)
    }

    @Test func relativePathsResolveAgainstCwd() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("one", ["a": "a\n"])
        let ctx = try await RepoResolver.resolve(directory: "./repo/", cwd: tmp.path)
        #expect(ctx.root == repo.path)
    }

    @Test func detachedHeadHasNoBranch() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        let sha = repo.commit("one", ["a": "a\n"])
        repo.git("checkout", "-q", "--detach", sha)
        let ctx = try await RepoResolver.resolve(directory: repo.path)
        #expect(ctx.branch == nil)
    }

    @Test func nonRepoIsAnError() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        await #expect(throws: RevuError("\(tmp.path) is not inside a git repository")) {
            try await RepoResolver.resolve(directory: tmp.path)
        }
    }

    @Test func missingDirectoryAndEmptyRepoAreErrors() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        await #expect(throws: RevuError("\(tmp.path)/nope is not a directory")) {
            try await RepoResolver.resolve(directory: tmp.path + "/nope")
        }
        let repo = try TestRepo.make(in: tmp)
        await #expect(throws: RevuError("\(repo.path) has no commits yet")) {
            try await RepoResolver.resolve(directory: repo.path)
        }
    }

    @Test func linkedWorktreeIsDetected() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp, name: "main-repo")
        repo.commit("one", ["a": "a\n"])
        let wt = tmp.path + "/feature-wt"
        repo.git("worktree", "add", "-q", "-b", "feature", wt)

        let ctx = try await RepoResolver.resolve(directory: wt)
        #expect(ctx.isWorktree)
        #expect(ctx.root == wt)
        #expect(ctx.branch == "feature")
        #expect(ctx.displayName == "main-repo ⎇ feature-wt")

        let main = try await RepoResolver.resolve(directory: repo.path)
        #expect(!main.isWorktree)
        #expect(main.commonDir == ctx.commonDir)
    }
}

@Suite struct BaseResolverTests {
    private func base(_ repo: TestRepo, override: String? = nil) async throws -> BaseSelection {
        let ctx = try await RepoResolver.resolve(directory: repo.path)
        return try await BaseResolver.resolve(for: ctx, override: override)
    }

    @Test func featureCutFromDevelopPicksDevelopEvenWhenMainDiverged() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("c1", ["a": "1\n"])
        repo.git("checkout", "-q", "-b", "develop")
        repo.commit("d1", ["d": "1\n"])
        let developTip = repo.commit("d2", ["d": "2\n"])
        repo.git("checkout", "-q", "-b", "feature/login")
        repo.commit("f1", ["f": "1\n"])
        repo.git("checkout", "-q", "main")
        for n in 1...4 { repo.commit("m\(n)", ["m": "\(n)\n"]) }
        repo.git("checkout", "-q", "feature/login")

        let result = try await base(repo)
        #expect(result.ref == "develop")
        #expect(result.mergeBase == developTip)
    }

    @Test func prefersRemoteTrackingCandidateAndOriginHeadOnTies() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let remote = try TestRepo.make(in: tmp, name: "remote.git")
        remote.git("config", "core.bare", "true")
        let repo = try TestRepo.make(in: tmp)
        let c1 = repo.commit("c1", ["a": "1\n"])
        repo.git("remote", "add", "origin", remote.path)
        repo.git("push", "-q", "origin", "main")
        repo.git("fetch", "-q", "origin")
        repo.git("remote", "set-head", "origin", "main")
        repo.git("checkout", "-q", "-b", "topic")
        repo.commit("t1", ["t": "1\n"])

        // local main == origin/main: tie on commit count, origin/HEAD target wins.
        let result = try await base(repo)
        #expect(result.ref == "origin/main")
        #expect(result.mergeBase == c1)
    }

    @Test func onDefaultBranchUsesUpstreamToShowUnpushedCommits() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let remote = try TestRepo.make(in: tmp, name: "remote.git")
        remote.git("config", "core.bare", "true")
        let repo = try TestRepo.make(in: tmp)
        let pushed = repo.commit("c1", ["a": "1\n"])
        repo.git("remote", "add", "origin", remote.path)
        repo.git("push", "-q", "-u", "origin", "main")
        repo.git("branch", "-q", "develop")          // a candidate that must be ignored on the default branch
        repo.commit("local", ["a": "2\n"])

        let result = try await base(repo)
        #expect(result.ref == "origin/main")
        #expect(result.mergeBase == pushed)
    }

    @Test func fallsBackToHeadWhenNothingElseExists() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        let sha = repo.commit("c1", ["a": "1\n"])
        let onMain = try await base(repo)
        #expect(onMain.ref == "HEAD")
        #expect(onMain.mergeBase == sha)

        repo.git("checkout", "-q", "-b", "scratch")
        repo.git("branch", "-q", "-D", "main")
        let lone = try await base(repo)
        #expect(lone.ref == "HEAD")
    }

    @Test func overrideWinsAndIsValidated() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        let c1 = repo.commit("c1", ["a": "1\n"])
        repo.git("checkout", "-q", "-b", "topic")
        repo.commit("t1", ["a": "2\n"])

        let result = try await base(repo, override: c1)
        #expect(result.ref == c1)
        #expect(result.mergeBase == c1)

        await #expect(throws: RevuError.self) { try await base(repo, override: "no-such-ref") }
    }
}

@Suite struct ChangeListerTests {
    @Test func includesCommittedStagedUnstagedAndUntracked() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["keep.txt": "1\n2\n3\n", "edit.txt": "a\nb\n", "gone.txt": "x\ny\n", "old name.txt": "same\ncontent\nhere\nfor\nrename\n"])
        let mb = repo.git("rev-parse", "HEAD")
        repo.git("checkout", "-q", "-b", "topic")
        repo.commit("committed", ["committed.txt": "c1\nc2\n"])
        repo.write("edit.txt", "a\nb\nc\n")
        repo.git("add", "edit.txt")                              // staged
        repo.write("keep.txt", "1\nTWO\n3\n")                    // unstaged
        repo.git("rm", "-q", "gone.txt")
        repo.git("mv", "old name.txt", "new name.txt")
        repo.write("untracked/new file.txt", "u1\nu2\nu3")       // no trailing newline
        repo.writeData("blob.bin", Data([0x00, 0x01, 0x02]))      // untracked binary
        repo.write(".gitignore-me", "")                           // untracked, empty

        let ctx = try await RepoResolver.resolve(directory: repo.path)
        let files = try await ChangeLister.list(in: ctx, mergeBase: mb)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        #expect(byPath["committed.txt"]?.status == .added)
        #expect(byPath["committed.txt"]?.additions == 2)
        #expect(byPath["edit.txt"]?.status == .modified)
        #expect(byPath["edit.txt"]?.additions == 1)
        #expect(byPath["keep.txt"]?.additions == 1)
        #expect(byPath["keep.txt"]?.deletions == 1)
        #expect(byPath["gone.txt"]?.status == .deleted)
        #expect(byPath["gone.txt"]?.deletions == 2)
        #expect(byPath["new name.txt"]?.status == .renamed)
        #expect(byPath["new name.txt"]?.oldPath == "old name.txt")
        #expect(byPath["untracked/new file.txt"]?.isUntracked == true)
        #expect(byPath["untracked/new file.txt"]?.additions == 3)
        #expect(byPath["blob.bin"]?.isBinary == true)
        #expect(byPath[".gitignore-me"]?.additions == 0)
        #expect(files.count == 8)
        #expect(byPath["old name.txt"] == nil)
    }

    @Test func trackedBinaryIsFlagged() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.writeData("img.bin", Data([0, 1, 2, 3]))
        repo.commit("base")
        let mb = repo.git("rev-parse", "HEAD")
        repo.writeData("img.bin", Data([0, 1, 2, 3, 4, 5]))
        let ctx = try await RepoResolver.resolve(directory: repo.path)
        let files = try await ChangeLister.list(in: ctx, mergeBase: mb)
        #expect(files.map(\.path) == ["img.bin"])
        #expect(files[0].isBinary)
    }

    @Test func parsesNumstatAndNameStatusWithRenames() {
        let numstat = Data("1\t2\ta.txt\0-\t-\tbin\0 0\t0\t\0old\0new\0".utf8)
        let counts = ChangeLister.parseNumstat(numstat)
        #expect(counts["a.txt"]?.additions == 1)
        #expect(counts["a.txt"]?.deletions == 2)
        #expect(counts["bin"]?.isBinary == true)

        let nameStatus = Data("M\0a.txt\0R090\0old\0new\0D\0gone\0".utf8)
        let files = ChangeLister.parseNameStatus(nameStatus, root: "/r", counts: counts)
        #expect(files.map(\.path) == ["a.txt", "new", "gone"])
        #expect(files[1].oldPath == "old")
        #expect(files[1].status == .renamed)
        #expect(files[2].status == .deleted)
    }
}

@Suite struct DiffLoaderTests {
    private func load(_ repo: TestRepo, mergeBase: String, path: String, force: Bool = false, gate: LargeDiffGate = .default) async throws -> LoadedDiff {
        let ctx = try await RepoResolver.resolve(directory: repo.path)
        let files = try await ChangeLister.list(in: ctx, mergeBase: mergeBase)
        let file = try #require(files.first { $0.path == path })
        return try await DiffLoader.load(file, mergeBase: mergeBase, force: force, gate: gate)
    }

    @Test func modifiedUntrackedAndRename() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["a.txt": "1\n2\n3\n", "r.txt": "r1\nr2\n"])
        let mb = repo.git("rev-parse", "HEAD")
        repo.write("a.txt", "1\nTWO\n3\n")
        repo.git("mv", "r.txt", "renamed with space.txt")
        repo.write("u u.txt", "x\ny\n")

        guard case let .diff(a) = try await load(repo, mergeBase: mb, path: "a.txt") else { Issue.record("expected diff"); return }
        #expect(a.lines.map(\.kind) == [.context, .removed, .added, .context])

        guard case let .diff(u) = try await load(repo, mergeBase: mb, path: "u u.txt") else { Issue.record("expected diff"); return }
        #expect(u.isNew)
        #expect(u.lines.map(\.text) == ["x", "y"])
        #expect(u.lines.map(\.newLine) == [1, 2])

        // Pure rename: git emits no hunks; the loader substitutes the file content as context.
        guard case let .diff(r) = try await load(repo, mergeBase: mb, path: "renamed with space.txt") else { Issue.record("expected diff"); return }
        #expect(r.isRename)
        #expect(r.oldPath == "r.txt")
        #expect(r.lines.map(\.text) == ["r1", "r2"])
        #expect(r.lines.allSatisfy { $0.kind == .context })
    }

    @Test func binaryReportsSizes() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.writeData("b.bin", Data([0, 1, 2]))
        repo.commit("base")
        let mb = repo.git("rev-parse", "HEAD")
        repo.writeData("b.bin", Data([0, 1, 2, 3, 4]))
        let result = try await load(repo, mergeBase: mb, path: "b.bin")
        #expect(result == .binary(BinaryInfo(oldSize: 3, newSize: 5)))
    }

    @Test func manyChangedLinesNeedForce() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["big.txt": "x\n"])
        let mb = repo.git("rev-parse", "HEAD")
        repo.write("big.txt", (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n")

        let small = LargeDiffGate(maxChangedLines: 20)
        let guarded = try await load(repo, mergeBase: mb, path: "big.txt", gate: small)
        #expect(guarded == .tooLarge(.changedLines(51)))      // 50 added + 1 removed
        let forced = try await load(repo, mergeBase: mb, path: "big.txt", force: true, gate: small)
        guard case let .diff(diff) = forced else { Issue.record("expected diff"); return }
        #expect(diff.lines.count == 51)
    }

    @Test func bigFilesNeedForceByBytes() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["a.txt": "x\n"])
        let mb = repo.git("rev-parse", "HEAD")
        repo.write("a.txt", String(repeating: "0123456789\n", count: 100))   // 1,100 bytes, 100 lines
        let result = try await load(repo, mergeBase: mb, path: "a.txt", gate: LargeDiffGate(maxBytes: 1_000))
        #expect(result == .tooLarge(.bytes(1_100)))
    }

    @Test func aOneLineChangeInAFiftyThousandLineFileOpensDirectly() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        let lines = (1...50_000).map { "let value\($0) = \($0)" }
        repo.commit("base", ["huge.swift": lines.joined(separator: "\n") + "\n"])
        let mb = repo.git("rev-parse", "HEAD")
        var edited = lines
        edited[25_000] = "let value25001 = CHANGED"
        repo.write("huge.swift", edited.joined(separator: "\n") + "\n")

        let result = try await load(repo, mergeBase: mb, path: "huge.swift")
        guard case let .diff(diff) = result else { Issue.record("expected a diff, got \(result)"); return }
        #expect(diff.lines.count == 50_001)
        let clock = ContinuousClock()
        var rows: [SideBySideRow] = []
        let elapsed = clock.measure { rows = SideBySide.build(diff: diff) }
        #expect(rows.count < 20)                       // one change, 3 lines of context each side, two separators
        #expect(elapsed < .seconds(1))
    }

    @Test func generatedFilesAreCollapsedUntilForced() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.write(".gitattributes", "vendor/*.txt linguist-generated\nkeep.min.js -linguist-generated\nraw.dat -diff\n")
        repo.commit("base", [
            "package-lock.json": "{}\n", "Data/Migrations/20240101_Init.Designer.cs": "a\n", "vendor/x.txt": "a\n",
            "keep.min.js": "a\n", "raw.dat": "a\n", "plain.txt": "a\n",
        ])
        let mb = repo.git("rev-parse", "HEAD")
        for f in ["package-lock.json", "Data/Migrations/20240101_Init.Designer.cs", "vendor/x.txt", "keep.min.js", "raw.dat", "plain.txt"] {
            repo.write(f, "b\n")
        }
        let ctx = try await RepoResolver.resolve(directory: repo.path)
        let files = try await ChangeLister.list(in: ctx, mergeBase: mb)
        let generated = Set(files.filter(\.isGenerated).map(\.path))
        #expect(generated == ["package-lock.json", "Data/Migrations/20240101_Init.Designer.cs", "vendor/x.txt", "raw.dat"])

        #expect(try await load(repo, mergeBase: mb, path: "package-lock.json") == .generated)
        guard case .diff = try await load(repo, mergeBase: mb, path: "package-lock.json", force: true) else {
            Issue.record("expected diff after forcing"); return
        }
        guard case .diff = try await load(repo, mergeBase: mb, path: "plain.txt") else { Issue.record("expected diff"); return }
    }
}

@Suite struct LargeDiffGateTests {
    @Test func gatesOnChangedLinesAndBytesButNotLength() {
        let gate = LargeDiffGate.default
        #expect(gate.reason(additions: 1, deletions: 1, workingBytes: 2_000_000, baseBytes: 2_000_000) == nil)
        #expect(gate.reason(additions: 5_000, deletions: 0, workingBytes: 10, baseBytes: nil) == nil)
        #expect(gate.reason(additions: 3_000, deletions: 2_001, workingBytes: 10, baseBytes: nil) == .changedLines(5_001))
        #expect(gate.reason(additions: 1, deletions: 0, workingBytes: 5 * 1024 * 1024, baseBytes: nil) == nil)
        #expect(gate.reason(additions: 1, deletions: 0, workingBytes: 5 * 1024 * 1024 + 1, baseBytes: nil) == .bytes(5 * 1024 * 1024 + 1))
        #expect(gate.reason(additions: 1, deletions: 0, workingBytes: 10, baseBytes: 6_000_000) == .bytes(6_000_000))
    }
}

@Suite struct RepoSnapshotTests {
    @Test func dedupesRepoRootsAndKeepsOrder() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let a = try TestRepo.make(in: tmp, name: "a")
        a.commit("c", ["f": "1\n"])
        let b = try TestRepo.make(in: tmp, name: "b")
        b.commit("c", ["f": "1\n"])
        a.write("f", "2\n")

        let targets = [RepoTarget(directory: a.path), RepoTarget(directory: b.path), RepoTarget(directory: a.path + "/.")]
        let snapshots = try await RepoSnapshot.loadAll(targets: targets, globalBase: nil)
        #expect(snapshots.map(\.context.displayName) == ["a", "b"])
        #expect(snapshots[0].files.map(\.path) == ["f"])
        #expect(snapshots[1].files.isEmpty)
    }

    @Test func perDirectoryOverrideBeatsGlobalBase() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let a = try TestRepo.make(in: tmp, name: "a")
        let c1 = a.commit("c1", ["f": "1\n"])
        a.commit("c2", ["f": "2\n"])
        let snapshots = try await RepoSnapshot.loadAll(
            targets: [RepoTarget(directory: a.path, baseOverride: c1)], globalBase: "HEAD")
        #expect(snapshots[0].base.ref == c1)
        #expect(snapshots[0].files.count == 1)
    }

    @Test func nonRepoFailsWithMessage() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        await #expect(throws: RevuError("\(tmp.path) is not inside a git repository")) {
            try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: tmp.path)], globalBase: nil)
        }
    }
}

@Suite struct RepoSnapshotReloadTests {
    @Test func reloadPicksUpNewChangesAndKeepsRequestedBase() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        let c1 = repo.commit("c1", ["f": "1\n"])
        let first = try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: repo.path, baseOverride: c1)], globalBase: nil)
        #expect(first[0].files.isEmpty)

        repo.write("f", "2\n")
        repo.write("g", "new\n")
        let second = try await first[0].reloaded()
        #expect(second.requestedBase == c1)
        #expect(second.base.ref == c1)
        #expect(second.files.map(\.path) == ["f", "g"])
    }
}

@Suite struct LoadGateAndOrderingTests {
    @Test func onlyTheLatestLoadForAFileIsCurrent() {
        var gate = LoadGate()
        let a = FileKey(repoRoot: "/r", path: "a"), b = FileKey(repoRoot: "/r", path: "b")
        let first = gate.begin(a)
        let other = gate.begin(b)
        #expect(gate.isCurrent(a, token: first))
        let second = gate.begin(a)             // e.g. a forced "Load anyway" racing the first load
        #expect(!gate.isCurrent(a, token: first))
        #expect(gate.isCurrent(a, token: second))
        #expect(gate.isCurrent(b, token: other))
    }

    @Test func invalidatingOneRepoLeavesOthersCurrent() {
        var gate = LoadGate()
        let a = FileKey(repoRoot: "/a", path: "f"), b = FileKey(repoRoot: "/b", path: "f")
        let ta = gate.begin(a), tb = gate.begin(b)
        gate.invalidate(repoRoot: "/a")
        #expect(!gate.isCurrent(a, token: ta))
        #expect(gate.isCurrent(b, token: tb))
    }

    @Test func loadAllThrowsTheFirstErrorInArgumentOrder() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // The first target needs git to fail; the second fails instantly without git, so it finishes first.
        let notRepo = tmp.path
        let missing = tmp.path + "/missing"
        await #expect(throws: RevuError("\(notRepo) is not inside a git repository")) {
            try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: notRepo), RepoTarget(directory: missing)], globalBase: nil)
        }
        await #expect(throws: RevuError("\(missing) is not a directory")) {
            try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: missing), RepoTarget(directory: notRepo)], globalBase: nil)
        }
    }
}

@Suite struct BrokenPipeTests {
    @Test func feedingInputToAGitThatExitsEarlyDoesNotKillTheProcess() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        ignoreSIGPIPE()
        // `rev-parse` outside a repo exits at once without reading stdin; 8 MB can't fit in the pipe.
        let big = Data(count: 8_000_000)
        for _ in 0..<5 {
            let result = await GitRunner.run(["rev-parse", "--show-toplevel"], in: tmp.path, input: big)
            #expect(result.exitCode != 0)
        }
    }

    @Test func aLargeInputThatGitReadsStillWorks() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["a": "1\n"])
        let paths = (0..<20_000).map { "dir/file-\($0).txt" }.joined(separator: "\0") + "\0"
        let result = await GitRunner.run(["check-ignore", "-z", "--stdin"], in: repo.path, input: Data(paths.utf8))
        #expect(result.exitCode == 1)                  // read everything, nothing ignored
    }
}
