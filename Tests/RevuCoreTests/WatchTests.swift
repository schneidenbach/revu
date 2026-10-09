import Testing
@testable import RevuCore

@Suite struct WatchFilterClassificationTests {
    private func kind(_ path: String, root: String = "/w/repo", gitDir: String = "/w/repo/.git", commonDir: String = "/w/repo/.git") -> WatchFilter.Kind {
        WatchFilter.classify(path, root: root, gitDir: gitDir, commonDir: commonDir)
    }

    @Test func onlyHeadIndexAndRefsInsideTheGitDirCount() {
        for rel in ["HEAD", "index", "ORIG_HEAD", "packed-refs", "refs/heads/main", "refs/remotes/origin/x", "refs/tags/v1"] {
            #expect(kind("/w/repo/.git/" + rel) == .gitRelevant, "\(rel)")
        }
        for rel in ["index.lock", "HEAD.lock", "refs/heads/main.lock", "objects/ab/cdef", "logs/HEAD", "FETCH_HEAD", "config", "COMMIT_EDITMSG", "refs", "packed-refs.lock", "hooks/pre-commit"] {
            #expect(kind("/w/repo/.git/" + rel) == .gitNoise, "\(rel)")
        }
    }

    @Test func worktreePathsAndNestedGitDirs() {
        #expect(kind("/w/repo/src/a.swift") == .worktree)
        #expect(kind("/w/repo/src/dir/") == .worktree)
        #expect(kind("/w/repo/.gitignore") == .worktree)
        #expect(kind("/w/repo/.github/workflows/ci.yml") == .worktree)
        #expect(kind("/w/repo/vendor/lib/.git/HEAD") == .gitNoise)
        #expect(kind("/w/repo/.git") == .gitNoise)
        #expect(kind("/elsewhere/file") == .outside)
        #expect(kind("/w/repository/file") == .outside)   // a sibling that merely shares the prefix
    }

    @Test func linkedWorktreeWatchesItsOwnGitDirAndTheSharedRefs() {
        func linked(_ p: String) -> WatchFilter.Kind {
            WatchFilter.classify(p, root: "/w/feature", gitDir: "/m/repo/.git/worktrees/feature", commonDir: "/m/repo/.git")
        }
        #expect(linked("/m/repo/.git/worktrees/feature/HEAD") == .gitRelevant)
        #expect(linked("/m/repo/.git/worktrees/feature/index") == .gitRelevant)
        #expect(linked("/m/repo/.git/refs/heads/feature") == .gitRelevant)
        #expect(linked("/m/repo/.git/packed-refs") == .gitRelevant)
        #expect(linked("/m/repo/.git/refs/heads/feature.lock") == .gitNoise)
        #expect(linked("/m/repo/.git/HEAD") == .gitNoise)          // the main checkout's HEAD is not ours
        #expect(linked("/m/repo/.git/objects/aa/bb") == .gitNoise)
        #expect(linked("/w/feature/.git") == .gitNoise)            // the `.git` pointer file
        #expect(linked("/w/feature/src/x.cs") == .worktree)
    }
}

@Suite struct WatchFilterIgnoreTests {
    private func relevant(_ repo: TestRepo, _ events: [String]) async -> Bool {
        let git = repo.path + "/.git"
        return await WatchFilter.hasRelevantChange(events: events, root: repo.path, gitDir: git, commonDir: git)
    }

    @Test func ignoredPathsDoNotTriggerButEverythingElseDoes() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", [".gitignore": "bin/\nobj/\n*.log\nnode_modules/\n", "src/a.cs": "a\n", "bin/tracked.dll": "x\n"])
        repo.git("add", "-f", "bin/tracked.dll")
        repo.commit("track a file inside an ignored dir")
        let p = repo.path

        // Build noise: existing and already-deleted files and directories under ignored dirs.
        repo.write("bin/Debug/app.dll", "x")
        #expect(await relevant(repo, [p + "/bin/Debug/app.dll", p + "/bin/Debug", p + "/obj/project.assets.json", p + "/debug.log"]) == false)
        #expect(await relevant(repo, [p + "/node_modules/left-pad/index.js", p + "/obj/gone/file.txt"]) == false)

        // Real work.
        #expect(await relevant(repo, [p + "/src/a.cs"]) == true)
        #expect(await relevant(repo, [p + "/src/new.cs"]) == true)
        #expect(await relevant(repo, [p + "/.gitignore"]) == true)
        #expect(await relevant(repo, [p + "/bin/tracked.dll"]) == true)               // tracked files are never ignored
        #expect(await relevant(repo, [p + "/bin/Debug/app.dll", p + "/src/a.cs"]) == true)   // one relevant path in a noisy batch
    }

    @Test func gitDirEventsAreFilteredWithoutAskingGit() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["a": "a\n"])
        let g = repo.path + "/.git"
        #expect(await relevant(repo, [g + "/objects/ab/cdef", g + "/index.lock", g + "/logs/HEAD", g + "/FETCH_HEAD"]) == false)
        #expect(await relevant(repo, [g + "/objects/ab/cdef", g + "/refs/heads/main"]) == true)
        #expect(await relevant(repo, [g + "/index"]) == true)
        #expect(await relevant(repo, [g + "/HEAD"]) == true)
        #expect(await relevant(repo, []) == false)
    }
}

@Suite struct RefreshCoalescerTests {
    @Test func firesOnceAfterTheLastEventWentQuiet() {
        var c = RefreshCoalescer(delay: 0.4)
        #expect(c.nextDeadline == nil)
        let p10 = c.poll(at: 10); #expect(!p10)
        c.noteEvent(at: 10.0)
        c.noteEvent(at: 10.3)                 // a burst keeps pushing the deadline out
        c.noteEvent(at: 10.6)
        #expect(c.nextDeadline == 11.0)
        let p10_9 = c.poll(at: 10.9); #expect(!p10_9)
        let p11_0 = c.poll(at: 11.0); #expect(p11_0)
        #expect(c.nextDeadline == nil)
        let p12 = c.poll(at: 12); #expect(!p12)              // nothing pending any more
    }

    @Test func neverRunsTwoAtOnceAndCoalescesEventsDuringARunIntoOneFollowUp() {
        var c = RefreshCoalescer(delay: 0.4)
        c.noteEvent(at: 0)
        let p0_5 = c.poll(at: 0.5); #expect(p0_5)
        c.noteEvent(at: 0.6)                  // three events while the first refresh runs
        c.noteEvent(at: 0.7)
        c.noteEvent(at: 0.8)
        let p5 = c.poll(at: 5); #expect(!p5)               // still running: no second refresh
        c.finish()
        let p1_0 = c.poll(at: 1.0); #expect(!p1_0)             // follow-up waits out the debounce too
        let p1_3 = c.poll(at: 1.3); #expect(p1_3)
        c.finish()
        let p9 = c.poll(at: 9); #expect(!p9)               // exactly one follow-up
    }
}

@Suite struct ViewedTrackerTests {
    private struct Setup {
        let tmp: TempDir
        let repo: TestRepo
        let mergeBase: String
        func files() async throws -> [ChangedFile] {
            let ctx = try await RepoResolver.resolve(directory: repo.path)
            return try await ChangeLister.list(in: ctx, mergeBase: mergeBase)
        }
        func key(_ path: String) -> FileKey { FileKey(repoRoot: repo.path, path: path) }
        func fingerprints() async throws -> [FileKey: String] {
            var result: [FileKey: String] = [:]
            for file in try await files() { result[file.key] = await ViewedTracker.fingerprint(of: file, mergeBase: mergeBase) }
            return result
        }
        func recheck(_ viewed: [FileKey: String], mergeBase override: String? = nil) async throws -> ViewedTracker.Outcome {
            await ViewedTracker.recheck(viewed: viewed, files: try await files(), mergeBases: [repo.path: override ?? mergeBase])
        }
    }

    private func setup() throws -> Setup {
        let tmp = try TempDir()
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", ["a.txt": "1\n2\n3\n", "b.txt": "x\n"])
        let mb = repo.git("rev-parse", "HEAD")
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("a.txt", "1\nTWO\n3\n")
        repo.write("b.txt", "y\n")
        repo.write("new.txt", "fresh\n")      // untracked
        return Setup(tmp: tmp, repo: repo, mergeBase: mb)
    }

    @Test func unchangedFilesStayViewed() async throws {
        let s = try setup(); defer { s.tmp.cleanup() }
        let viewed = try await s.fingerprints()
        #expect(viewed.count == 3)
        let outcome = try await s.recheck(viewed)
        #expect(outcome == ViewedTracker.Outcome())
    }

    @Test func editingAFileMarksItChanged() async throws {
        let s = try setup(); defer { s.tmp.cleanup() }
        let viewed = try await s.fingerprints()
        s.repo.write("a.txt", "1\nTWO\n3\n4\n")
        s.repo.write("new.txt", "fresh\nmore\n")
        let outcome = try await s.recheck(viewed)
        #expect(outcome.changed == [s.key("a.txt"), s.key("new.txt")])   // b.txt untouched
    }

    @Test func touchingWithoutChangingContentKeepsItViewed() async throws {
        let s = try setup(); defer { s.tmp.cleanup() }
        let viewed = try await s.fingerprints()
        s.repo.write("a.txt", "1\nTWO\n3\n")             // rewritten with identical content (new mtime)
        s.repo.write("new.txt", "fresh\n")
        #expect(try await s.recheck(viewed).changed.isEmpty)
    }

    @Test func aNewCommitThatLeavesTheDiffAloneKeepsItViewed() async throws {
        let s = try setup(); defer { s.tmp.cleanup() }
        let viewed = try await s.fingerprints()
        s.repo.git("add", "-A")
        s.repo.git("commit", "-q", "-m", "commit the work so far")     // same content, now committed
        s.repo.commit("unrelated", ["c.txt": "other\n"])
        let outcome = try await s.recheck(viewed)
        #expect(outcome.changed.isEmpty)
    }

    @Test func aDifferentMergeBaseMarksEverythingChanged() async throws {
        let s = try setup(); defer { s.tmp.cleanup() }
        let viewed = try await s.fingerprints()
        let other = s.repo.commit("moves the base", ["c.txt": "other\n"])
        let outcome = try await s.recheck(viewed, mergeBase: other)
        // The diff text of a.txt is the same either way, but it was viewed against a different base.
        #expect(outcome.changed.contains(s.key("a.txt")))
        #expect(outcome.changed.contains(s.key("b.txt")))
    }

    @Test func unknownFingerprintsAreFilledAndFilesOutOfTheListAreIgnored() async throws {
        let s = try setup(); defer { s.tmp.cleanup() }
        let known = try await s.fingerprints()
        let viewed = [s.key("a.txt"): ViewedTracker.unknown, s.key("gone.txt"): "whatever"]
        let outcome = try await s.recheck(viewed)
        #expect(outcome.changed.isEmpty)
        #expect(outcome.filled == [s.key("a.txt"): known[s.key("a.txt")]!])
    }
}

@Suite struct DraftCompatibilityTests {
    @Test func olderDraftsWithPlainViewedSetsDecodeWithoutFingerprints() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let key = DraftStore.key(for: ["/r"])
        try tmp.write("\(key).json", """
            {"comments":[],"summary":"s","viewed":[{"repoRoot":"/r","path":"a.txt"},{"repoRoot":"/r","path":"b.txt"}]}
            """)
        let draft = try #require(DraftStore(directory: tmp.url).load(roots: ["/r"]))
        #expect(draft.summary == "s")
        #expect(draft.viewed == [
            FileKey(repoRoot: "/r", path: "a.txt"): ViewedTracker.unknown,
            FileKey(repoRoot: "/r", path: "b.txt"): ViewedTracker.unknown,
        ])
    }

    @Test func fingerprintsRoundTrip() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let store = DraftStore(directory: tmp.url)
        let draft = ReviewDraft(viewed: [FileKey(repoRoot: "/r", path: "a"): "f1", FileKey(repoRoot: "/r", path: "b"): ViewedTracker.unknown])
        try store.save(draft, roots: ["/r"])
        #expect(store.load(roots: ["/r"]) == draft)
    }

    @Test func missingFieldsDecodeAsEmpty() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("\(DraftStore.key(for: ["/r"])).json", "{}")
        #expect(DraftStore(directory: tmp.url).load(roots: ["/r"]) == ReviewDraft())
    }
}

@Suite struct RefreshRetryPolicyTests {
    @Test func retriesTwiceThenGivesUp() {
        var policy = RefreshRetryPolicy(delay: 1.5, maxConsecutiveFailures: 3)
        #expect(policy.recordFailure() == 1.5)
        #expect(policy.recordFailure() == 1.5)
        #expect(policy.recordFailure() == nil)        // third consecutive failure: stop and leave the banner up
        #expect(policy.failures == 3)
    }

    @Test func aSuccessOrANewRequestStartsAFreshSeries() {
        var policy = RefreshRetryPolicy()
        _ = policy.recordFailure()
        _ = policy.recordFailure()
        policy.recordSuccess()
        #expect(policy.failures == 0)
        #expect(policy.recordFailure() == 1.5)
        _ = policy.recordFailure()
        policy.reset()
        #expect(policy.recordFailure() == 1.5)
    }

    @Test func aRetryGoesThroughTheCoalescerWithoutALoop() {
        // After a failed run the driver schedules the retry as an ordinary event `delay` in the future.
        var c = RefreshCoalescer(delay: 0.4)
        c.noteEvent(at: 0)
        let first = c.poll(at: 0.4)
        #expect(first)
        c.finish()                                     // failed
        c.noteEvent(at: 0.4 + 1.5 - 0.4)               // request(after: 1.5)
        #expect(c.nextDeadline == 1.9)
        let tooEarly = c.poll(at: 1.0)
        #expect(!tooEarly)
        let retry = c.poll(at: 1.9)
        #expect(retry)
        c.finish()
        let again = c.poll(at: 99)
        #expect(!again)                                // nothing pending: no tight loop
    }
}
