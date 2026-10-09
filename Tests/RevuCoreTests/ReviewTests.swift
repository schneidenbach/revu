import Testing
@testable import RevuCore

private let acx = ReviewRepoInfo(name: "AcxPlatform2", root: "/r/AcxPlatform2", branch: "feature/login", base: "origin/develop", mergeBase: "aaa111")
private let data = ReviewRepoInfo(name: "Data", root: "/r/Data", branch: nil, base: "origin/main", mergeBase: "bbb222")
private let untouched = ReviewRepoInfo(name: "Quiet", root: "/r/Quiet", branch: "main", base: "HEAD", mergeBase: "ccc333")

private func fixedReview() -> (ReviewSubmission, outdatedID: UUID) {
    let outdatedID = UUID()
    let comments = [
        Comment(anchor: Anchor(repoRoot: acx.root, path: "src/Auth/LoginService.cs", side: .new, startLine: 42, endLine: 44,
                               lineText: "if (user == null)\n    return null;\nvar token = Issue(user);"),
                body: "Comment text verbatim.\nSecond line."),
        Comment(id: outdatedID, anchor: Anchor(repoRoot: acx.root, path: "src/Auth/LoginService.cs", side: .old, startLine: 10, endLine: 11,
                               lineText: "old a\nold b"),
                body: "Why was this removed?"),
        Comment(anchor: Anchor(repoRoot: acx.root, path: "src/Auth/LoginService.cs"), body: "Whole file note."),
        Comment(anchor: Anchor(repoRoot: data.root, path: "Models/User.cs", side: .new, startLine: 7, lineText: "public string Name;"),
                body: "Use a record."),
    ]
    let review = ReviewSubmission(
        verdict: .requestChanges, summary: "Please fix the auth flow.", repos: [acx, data, untouched],
        comments: comments, outdated: [outdatedID],
        oldPaths: [FileKey(repoRoot: acx.root, path: "src/Auth/LoginService.cs"): "src/Auth/Login.cs"])
    return (review, outdatedID)
}

@Suite struct ReviewRendererTests {
    @Test func markdownSnapshot() {
        let expected = #"""
        # Code review — CHANGES REQUESTED

        Please fix the auth flow.

        **4 comments across 2 repos.** Line numbers refer to the working-tree file unless marked (removed).

        ## AcxPlatform2 · feature/login → origin/develop
        Root: /r/AcxPlatform2

        ### src/Auth/LoginService.cs

        **/r/AcxPlatform2/src/Auth/LoginService.cs:42-44**
        ```
        42 | if (user == null)
        43 |     return null;
        44 | var token = Issue(user);
        ```
        Comment text verbatim.
        Second line.

        **/r/AcxPlatform2/src/Auth/LoginService.cs (removed lines 10-11 from base, was src/Auth/Login.cs)** _(outdated)_
        ```
        10 | old a
        11 | old b
        ```
        Why was this removed?

        **File comment:** Whole file note.

        ## Data · detached HEAD → origin/main
        Root: /r/Data

        ### Models/User.cs

        **/r/Data/Models/User.cs:7**
        ```
        7 | public string Name;
        ```
        Use a record.

        """#
        #expect(ReviewRenderer.markdown(fixedReview().0) == expected)
    }

    @Test func jsonSnapshot() throws {
        let expected = #"""
        {
          "repos" : [
            {
              "base" : "origin/develop",
              "branch" : "feature/login",
              "files" : [
                {
                  "absolutePath" : "/r/AcxPlatform2/src/Auth/LoginService.cs",
                  "comments" : [
                    {
                      "body" : "Comment text verbatim.\nSecond line.",
                      "code" : "if (user == null)\n    return null;\nvar token = Issue(user);",
                      "endLine" : 44,
                      "outdated" : false,
                      "side" : "new",
                      "startLine" : 42
                    },
                    {
                      "body" : "Why was this removed?",
                      "code" : "old a\nold b",
                      "endLine" : 11,
                      "outdated" : true,
                      "side" : "old",
                      "startLine" : 10
                    },
                    {
                      "body" : "Whole file note.",
                      "code" : "",
                      "endLine" : null,
                      "outdated" : false,
                      "side" : "new",
                      "startLine" : null
                    }
                  ],
                  "oldPath" : "src/Auth/Login.cs",
                  "path" : "src/Auth/LoginService.cs"
                }
              ],
              "mergeBase" : "aaa111",
              "name" : "AcxPlatform2",
              "root" : "/r/AcxPlatform2"
            },
            {
              "base" : "origin/main",
              "branch" : null,
              "files" : [
                {
                  "absolutePath" : "/r/Data/Models/User.cs",
                  "comments" : [
                    {
                      "body" : "Use a record.",
                      "code" : "public string Name;",
                      "endLine" : 7,
                      "outdated" : false,
                      "side" : "new",
                      "startLine" : 7
                    }
                  ],
                  "path" : "Models/User.cs"
                }
              ],
              "mergeBase" : "bbb222",
              "name" : "Data",
              "root" : "/r/Data"
            }
          ],
          "summary" : "Please fix the auth flow.",
          "verdict" : "request_changes"
        }
        """#
        #expect(try ReviewRenderer.json(fixedReview().0) == expected)
    }

    @Test func oldPathOnlyAppearsForRenamedFilesAndOldSideComments() {
        let key = FileKey(repoRoot: acx.root, path: "b.cs")
        let old = Comment(anchor: Anchor(repoRoot: acx.root, path: "b.cs", side: .old, startLine: 3, lineText: "x"), body: "o")
        let new = Comment(anchor: Anchor(repoRoot: acx.root, path: "b.cs", side: .new, startLine: 4, lineText: "y"), body: "n")
        let review = ReviewSubmission(verdict: .comment, summary: "", repos: [acx], comments: [old, new], oldPaths: [key: "a.cs"])
        let md = ReviewRenderer.markdown(review)
        #expect(md.contains("b.cs (removed line 3 from base, was a.cs)**"))
        #expect(md.contains("b.cs:4**"))
        #expect(!md.contains("b.cs:4, was"))
        let plain = ReviewSubmission(verdict: .comment, summary: "", repos: [acx], comments: [old])
        #expect(ReviewRenderer.markdown(plain).contains("b.cs (removed line 3 from base)**"))
        #expect(try! !ReviewRenderer.json(plain).contains("oldPath"))
    }

    @Test func approveWithoutCommentsIsJustHeadingSummaryAndNoComments() {
        let review = ReviewSubmission(verdict: .approve, summary: "", repos: [acx], comments: [])
        #expect(ReviewRenderer.markdown(review) == "# Code review — APPROVED\n\n_No summary._\n\nNo comments.\n")
        let withSummary = ReviewSubmission(verdict: .approve, summary: "Looks good.\n", repos: [acx], comments: [])
        #expect(ReviewRenderer.markdown(withSummary) == "# Code review — APPROVED\n\nLooks good.\n\nNo comments.\n")
    }

    @Test func singularWordingAndCommentVerdict() {
        let c = Comment(anchor: Anchor(repoRoot: acx.root, path: "a.swift"), body: "hm")
        let review = ReviewSubmission(verdict: .comment, summary: "", repos: [acx], comments: [c])
        let md = ReviewRenderer.markdown(review)
        #expect(md.hasPrefix("# Code review — COMMENTED\n"))
        #expect(md.contains("**1 comment across 1 repo.**"))
    }

    @Test func codeContainingBackticksGetsALongerFence() {
        let anchor = Anchor(repoRoot: acx.root, path: "a.md", side: .new, startLine: 1, lineText: "```swift")
        let review = ReviewSubmission(verdict: .comment, summary: "", repos: [acx], comments: [Comment(anchor: anchor, body: "x")])
        #expect(ReviewRenderer.markdown(review).contains("````\n1 | ```swift\n````\n"))
    }

    @Test func lineNumbersInSnippetsAreRightAligned() {
        let text = (98...101).map { "l\($0)" }.joined(separator: "\n")
        let anchor = Anchor(repoRoot: acx.root, path: "a.txt", side: .new, startLine: 98, endLine: 101, lineText: text)
        let review = ReviewSubmission(verdict: .comment, summary: "", repos: [acx], comments: [Comment(anchor: anchor, body: "x")])
        #expect(ReviewRenderer.markdown(review).contains(" 98 | l98\n 99 | l99\n100 | l100\n101 | l101\n"))
    }

    @Test func commentsAreOrderedNewOldThenFileLevelAndByLine() {
        func c(_ side: Side, _ line: Int?, _ body: String) -> Comment {
            Comment(anchor: Anchor(repoRoot: acx.root, path: "a.txt", side: side, startLine: line), body: body)
        }
        let review = ReviewSubmission(
            verdict: .comment, summary: "", repos: [acx],
            comments: [c(.new, nil, "zz-file"), c(.old, 3, "zz-old3"), c(.new, 9, "zz-new9"), c(.new, 2, "zz-new2")])
        let md = ReviewRenderer.markdown(review)
        let order = ["zz-new2", "zz-new9", "zz-old3", "zz-file"].map { md.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
    }
}

@Suite struct CommentOutdatedTests {
    private func comment(_ side: Side, _ start: Int, _ end: Int, _ text: String) -> Comment {
        Comment(anchor: Anchor(repoRoot: "/r", path: "f", side: side, startLine: start, endLine: end, lineText: text), body: "b")
    }

    @Test func matchingLinesAreCurrent() {
        let diff = makeDiff(" a", "-b", "+B", " c")
        #expect(!comment(.new, 2, 3, "B\nc").isOutdated(in: diff))
        #expect(!comment(.old, 2, 2, "b").isOutdated(in: diff))
    }

    @Test func changedOrMissingLinesAreOutdated() {
        let diff = makeDiff(" a", "-b", "+B", " c")
        #expect(comment(.new, 2, 2, "stale").isOutdated(in: diff))
        #expect(comment(.new, 40, 40, "B").isOutdated(in: diff))
        #expect(comment(.new, 2, 2, "B").isOutdated(in: nil))
    }

    @Test func fileLevelCommentsAreNeverOutdated() {
        let c = Comment(anchor: Anchor(repoRoot: "/r", path: "f"), body: "b")
        #expect(!c.isOutdated(in: nil))
        #expect(!c.isOutdated(in: makeDiff(" a")))
    }
}

@Suite struct DraftStoreTests {
    @Test func roundTripsAndDeletes() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let store = DraftStore(directory: tmp.url)
        let roots = ["/r/b", "/r/a"]
        #expect(store.load(roots: roots) == nil)

        let draft = ReviewDraft(
            comments: [Comment(anchor: Anchor(repoRoot: "/r/a", path: "x", side: .old, startLine: 1, lineText: "t"), body: "hi")],
            summary: "sum", viewed: [FileKey(repoRoot: "/r/a", path: "x"): "abc123"])
        try store.save(draft, roots: roots)
        #expect(store.load(roots: roots) == draft)
        #expect(store.load(roots: ["/r/a", "/r/b"]) == draft)   // order of roots does not matter
        #expect(store.load(roots: ["/r/a"]) == nil)

        store.delete(roots: roots)
        #expect(store.load(roots: roots) == nil)
    }

    @Test func savingAnEmptyDraftRemovesTheFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let store = DraftStore(directory: tmp.url)
        try store.save(ReviewDraft(summary: "x"), roots: ["/r"])
        #expect(store.load(roots: ["/r"]) != nil)
        try store.save(ReviewDraft(), roots: ["/r"])
        #expect(store.load(roots: ["/r"]) == nil)
    }

    @Test func keyIsStableSha256OfSortedRoots() {
        #expect(DraftStore.key(for: ["/b", "/a"]) == DraftStore.key(for: ["/a", "/b"]))
        #expect(DraftStore.key(for: ["/a"]) != DraftStore.key(for: ["/b"]))
        #expect(DraftStore.key(for: ["/a"]).count == 64)
    }

    @Test func corruptDraftIsIgnored() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let store = DraftStore(directory: tmp.url)
        try tmp.write("\(DraftStore.key(for: ["/r"])).json", "not json")
        #expect(store.load(roots: ["/r"]) == nil)
    }
}

@Suite struct ReviewArchiveTests {
    @Test func writesTimestampedMarkdownAndJson() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let archive = ReviewArchive(directory: tmp.url.appendingPathComponent("reviews"))
        let url = try archive.save(markdown: "# md", json: "{}", date: tmp.date(2026, 10, 8, 13, 5, 9))
        #expect(url.lastPathComponent == "20261008-130509.md")
        #expect(tmp.read("reviews/20261008-130509.md") == "# md")
        #expect(tmp.read("reviews/20261008-130509.json") == "{}")
    }
}

@Suite struct ArgumentsTests {
    private func parse(_ args: String..., dirs: Set<String> = []) -> ParsedArguments {
        Arguments.parse(args, isDirectory: { dirs.contains($0) })
    }

    @Test func plainDirectories() {
        guard case let .run(o) = parse("a", "b") else { Issue.record("expected run"); return }
        #expect(o.targets == [RepoTarget(directory: "a"), RepoTarget(directory: "b")])
        #expect(o.base == nil && !o.json && o.output == nil && o.title == nil)
    }

    @Test func allOptionsInBothSpellings() {
        guard case let .run(o) = parse("--base", "origin/develop", "--json", "--output=/tmp/r.md", "--title", "My review", "a") else {
            Issue.record("expected run"); return
        }
        #expect(o.base == "origin/develop")
        #expect(o.json)
        #expect(o.output == "/tmp/r.md")
        #expect(o.title == "My review")
        guard case let .run(o2) = parse("a", "--base=main") else { Issue.record("expected run"); return }
        #expect(o2.base == "main")
    }

    @Test func perDirectoryBaseOverride() {
        guard case let .run(o) = parse("../Data=origin/develop", "plain") else { Issue.record("expected run"); return }
        #expect(o.targets == [RepoTarget(directory: "../Data", baseOverride: "origin/develop"), RepoTarget(directory: "plain")])
    }

    @Test func existingDirectoryWithEqualsSignIsNotAnOverride() {
        guard case let .run(o) = parse("weird=name", dirs: ["weird=name"]) else { Issue.record("expected run"); return }
        #expect(o.targets == [RepoTarget(directory: "weird=name")])
    }

    @Test func doubleDashEndsOptions() {
        guard case let .run(o) = parse("--", "--json") else { Issue.record("expected run"); return }
        #expect(o.targets == [RepoTarget(directory: "--json")])
        #expect(!o.json)
    }

    @Test func helpWinsAnywhere() {
        #expect(parse("--help") == .help)
        #expect(parse("a", "-h") == .help)
    }

    @Test func versionFlag() {
        #expect(parse("--version") == .version)
        #expect(parse("a", "--version") == .version)
        #expect(!Arguments.usage.isEmpty && Arguments.usage.contains("--version"))
        #expect(!Version.current.isEmpty)
        #expect(Version.current.split(separator: ".").count == 3)
    }

    @Test func usageErrors() {
        #expect(parse() == .failure("no directories given"))
        #expect(parse("--json") == .failure("no directories given"))
        #expect(parse("--base") == .failure("--base needs a value"))
        #expect(parse("--bogus", "a") == .failure("unknown option --bogus"))
        #expect(parse("-x", "a") == .failure("unknown option -x"))
    }
}
