import Foundation

public enum ReviewRenderer {
    // MARK: Markdown

    public static func markdown(_ review: ReviewSubmission) -> String {
        var out = "# Code review — \(headline(review.verdict))\n\n"
        let summary = review.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        out += (summary.isEmpty ? "_No summary._" : summary) + "\n\n"

        let groups = grouped(review)
        guard !review.comments.isEmpty else {
            return out + "No comments.\n"
        }
        let count = review.comments.count
        out += "**\(count) comment\(count == 1 ? "" : "s") across \(groups.count) repo\(groups.count == 1 ? "" : "s").** "
        out += "Line numbers refer to the working-tree file unless marked (removed).\n"

        for group in groups {
            out += "\n## \(group.repo.name) · \(branchLabel(group.repo))\n"
            out += "Root: \(group.repo.root)\n"
            for file in group.files {
                out += "\n### \(file.path)\n"
                let absolute = group.repo.root + "/" + file.path
                for comment in file.comments {
                    out += "\n" + markdownComment(
                        comment, absolutePath: absolute, oldPath: review.oldPaths[FileKey(repoRoot: group.repo.root, path: file.path)],
                        outdated: review.outdated.contains(comment.id))
                }
            }
        }
        return out
    }

    private static func headline(_ verdict: Verdict) -> String {
        switch verdict {
        case .requestChanges: "CHANGES REQUESTED"
        case .comment: "COMMENTED"
        case .approve: "APPROVED"
        }
    }

    private static func branchLabel(_ repo: ReviewRepoInfo) -> String {
        "\(repo.branch ?? "detached HEAD") → \(repo.base)"
    }

    private static func markdownComment(_ comment: Comment, absolutePath: String, oldPath: String?, outdated: Bool) -> String {
        let anchor = comment.anchor
        let flag = outdated ? " _(outdated)_" : ""
        guard let start = anchor.startLine else {
            return "**File comment:** \(comment.body)\n"
        }
        let end = anchor.endLine ?? start
        let range = start == end ? "\(start)" : "\(start)-\(end)"
        var out: String
        switch anchor.side {
        case .new:
            out = "**\(absolutePath):\(range)**\(flag)\n"
        case .old:
            let was = oldPath.map { ", was \($0)" } ?? ""
            out = "**\(absolutePath) (removed line\(start == end ? "" : "s") \(range) from base\(was))**\(flag)\n"
        }
        if !anchor.lineText.isEmpty {
            let texts = anchor.lineText.components(separatedBy: "\n")
            let width = String(start + texts.count - 1).count
            let code = texts.enumerated()
                .map { offset, text in String(repeating: " ", count: width - String(start + offset).count) + "\(start + offset) | \(text)" }
                .joined(separator: "\n")
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: code) + 1))
            out += "\(fence)\n\(code)\n\(fence)\n"
        }
        return out + comment.body + "\n"
    }

    private static func longestBacktickRun(in s: String) -> Int {
        var best = 0, run = 0
        for ch in s {
            run = ch == "`" ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    // MARK: JSON

    public static func json(_ review: ReviewSubmission) throws -> String {
        let payload = JSONReview(
            verdict: review.verdict.rawValue,
            summary: review.summary,
            repos: grouped(review).map { group in
                JSONRepo(
                    root: group.repo.root, name: group.repo.name, branch: group.repo.branch,
                    base: group.repo.base, mergeBase: group.repo.mergeBase,
                    files: group.files.map { file in
                        JSONFile(
                            path: file.path, oldPath: review.oldPaths[FileKey(repoRoot: group.repo.root, path: file.path)],
                            absolutePath: group.repo.root + "/" + file.path,
                            comments: file.comments.map { c in
                                JSONComment(
                                    side: c.anchor.side.rawValue, startLine: c.anchor.startLine, endLine: c.anchor.endLine,
                                    code: c.anchor.lineText, body: c.body, outdated: review.outdated.contains(c.id))
                            })
                    })
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private struct JSONReview: Encodable { var verdict: String; var summary: String; var repos: [JSONRepo] }
    private struct JSONRepo: Encodable {
        var root: String, name: String, branch: String?, base: String, mergeBase: String, files: [JSONFile]
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(root, forKey: .root); try c.encode(name, forKey: .name)
            try c.encode(branch, forKey: .branch)  // explicit null when detached
            try c.encode(base, forKey: .base); try c.encode(mergeBase, forKey: .mergeBase)
            try c.encode(files, forKey: .files)
        }
        enum CodingKeys: String, CodingKey { case root, name, branch, base, mergeBase, files }
    }
    /// `oldPath` is omitted unless the file was renamed.
    private struct JSONFile: Encodable { var path: String; var oldPath: String?; var absolutePath: String; var comments: [JSONComment] }
    private struct JSONComment: Encodable {
        var side: String, startLine: Int?, endLine: Int?, code: String, body: String, outdated: Bool
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(side, forKey: .side)
            try c.encode(startLine, forKey: .startLine); try c.encode(endLine, forKey: .endLine)
            try c.encode(code, forKey: .code); try c.encode(body, forKey: .body); try c.encode(outdated, forKey: .outdated)
        }
        enum CodingKeys: String, CodingKey { case side, startLine, endLine, code, body, outdated }
    }

    // MARK: Grouping

    private struct FileGroup { var path: String; var comments: [Comment] }
    private struct RepoGroup { var repo: ReviewRepoInfo; var files: [FileGroup] }

    /// Repos with comments (in the order given), files sorted by path, comments by new side, old side, then file-level.
    private static func grouped(_ review: ReviewSubmission) -> [RepoGroup] {
        review.repos.compactMap { repo in
            let inRepo = review.comments.filter { $0.anchor.repoRoot == repo.root }
            guard !inRepo.isEmpty else { return nil }
            let byPath = Dictionary(grouping: inRepo, by: { $0.anchor.path })
            let files = byPath.keys.sorted().map { path in
                FileGroup(path: path, comments: byPath[path]!.sorted(by: commentOrder))
            }
            return RepoGroup(repo: repo, files: files)
        }
    }

    private static func commentOrder(_ a: Comment, _ b: Comment) -> Bool {
        func rank(_ c: Comment) -> Int { c.anchor.isFileLevel ? 2 : (c.anchor.side == .new ? 0 : 1) }
        let (ra, rb) = (rank(a), rank(b))
        if ra != rb { return ra < rb }
        return (a.anchor.startLine ?? 0, a.anchor.endLine ?? 0) < (b.anchor.startLine ?? 0, b.anchor.endLine ?? 0)
    }
}
