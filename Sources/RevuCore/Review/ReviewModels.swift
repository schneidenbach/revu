import Foundation

public enum Verdict: String, Codable, CaseIterable, Sendable {
    case requestChanges = "request_changes"
    case comment
    case approve

    public var title: String {
        switch self {
        case .requestChanges: "Request changes"
        case .comment: "Comment"
        case .approve: "Approve"
        }
    }
}

/// Where a comment points. File-level comments have no lines.
public struct Anchor: Codable, Hashable, Sendable {
    public var repoRoot: String
    public var path: String
    public var side: Side
    public var startLine: Int?
    public var endLine: Int?
    /// The anchored lines' text when the comment was written, joined with `\n`.
    public var lineText: String

    public init(repoRoot: String, path: String, side: Side = .new, startLine: Int? = nil, endLine: Int? = nil, lineText: String = "") {
        self.repoRoot = repoRoot
        self.path = path
        self.side = side
        self.startLine = startLine
        self.endLine = endLine ?? startLine
        self.lineText = lineText
    }

    public var isFileLevel: Bool { startLine == nil }
    public var fileKey: FileKey { FileKey(repoRoot: repoRoot, path: path) }
}

public struct Comment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var anchor: Anchor
    public var body: String

    public init(id: UUID = UUID(), anchor: Anchor, body: String) {
        self.id = id
        self.anchor = anchor
        self.body = body
    }

    /// A line comment is outdated when the lines it was written against no longer match the current
    /// file (or the file has no diff any more). File-level comments are never outdated.
    public func isOutdated(in diff: FileDiff?) -> Bool {
        guard let start = anchor.startLine else { return false }
        guard let diff else { return true }
        return diff.text(side: anchor.side, from: start, to: anchor.endLine ?? start) != anchor.lineText
    }
}

/// Everything worth keeping if the app is closed mid-review.
public struct ReviewDraft: Codable, Equatable, Sendable {
    public var comments: [Comment]
    public var summary: String
    /// Viewed files with the fingerprint of what was viewed (`ViewedTracker.unknown` if not yet computed).
    public var viewed: [FileKey: String]

    public init(comments: [Comment] = [], summary: String = "", viewed: [FileKey: String] = [:]) {
        self.comments = comments
        self.summary = summary
        self.viewed = viewed
    }

    public var isEmpty: Bool { comments.isEmpty && summary.isEmpty && viewed.isEmpty }

    private struct ViewedEntry: Codable {
        var repoRoot: String
        var path: String
        /// Absent in drafts written before fingerprints existed (those stored plain file keys).
        var fingerprint: String?
    }

    private enum CodingKeys: String, CodingKey { case comments, summary, viewed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        let entries = try c.decodeIfPresent([ViewedEntry].self, forKey: .viewed) ?? []
        viewed = Dictionary(
            entries.map { (FileKey(repoRoot: $0.repoRoot, path: $0.path), $0.fingerprint ?? ViewedTracker.unknown) },
            uniquingKeysWith: { first, _ in first })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(comments, forKey: .comments)
        try c.encode(summary, forKey: .summary)
        let entries = viewed
            .map { ViewedEntry(repoRoot: $0.key.repoRoot, path: $0.key.path, fingerprint: $0.value) }
            .sorted { ($0.repoRoot, $0.path) < ($1.repoRoot, $1.path) }
        try c.encode(entries, forKey: .viewed)
    }
}

public struct ReviewRepoInfo: Codable, Hashable, Sendable {
    public var name: String
    public var root: String
    public var branch: String?
    public var base: String
    public var mergeBase: String

    public init(name: String, root: String, branch: String?, base: String, mergeBase: String) {
        self.name = name
        self.root = root
        self.branch = branch
        self.base = base
        self.mergeBase = mergeBase
    }
}

/// The final review handed to the renderer.
public struct ReviewSubmission: Sendable {
    public var verdict: Verdict
    public var summary: String
    public var repos: [ReviewRepoInfo]
    public var comments: [Comment]
    public var outdated: Set<UUID>
    /// Pre-rename path of renamed files, so old-side comments can say where the removed lines lived.
    public var oldPaths: [FileKey: String]

    public init(
        verdict: Verdict, summary: String, repos: [ReviewRepoInfo], comments: [Comment],
        outdated: Set<UUID> = [], oldPaths: [FileKey: String] = [:]
    ) {
        self.oldPaths = oldPaths
        self.verdict = verdict
        self.summary = summary
        self.repos = repos
        self.comments = comments
        self.outdated = outdated
    }
}
