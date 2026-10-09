import Foundation

/// Decides whether a batch of file-system events should trigger a refresh. Build output and other
/// ignored files change constantly, so most events must be dropped before any work is done.
public enum WatchFilter {
    public enum Kind: Equatable, Sendable {
        /// A git-dir change that moves HEAD, the index or a ref (commit, checkout, `git add`, ...).
        case gitRelevant
        /// Anything else inside a git dir, or any nested `.git`.
        case gitNoise
        /// A path in the working tree; still has to pass the ignore check.
        case worktree
        /// Not part of this repo at all.
        case outside
    }

    private static let gitDirFiles: Set<String> = ["HEAD", "index", "ORIG_HEAD", "packed-refs"]

    /// Classifies one event path. Paths may be absolute or end in "/".
    public static func classify(_ path: String, root: String, gitDir: String, commonDir: String) -> Kind {
        let path = trimmed(path)
        if let rel = relative(path, to: gitDir) {
            return isRelevantGitPath(rel) ? .gitRelevant : .gitNoise
        }
        if commonDir != gitDir, let rel = relative(path, to: commonDir) {
            // A linked worktree shares the main repo's refs; only those matter there.
            return (rel == "packed-refs" || rel.hasPrefix("refs/")) && !rel.hasSuffix(".lock") ? .gitRelevant : .gitNoise
        }
        guard let rel = relative(path, to: root) else { return .outside }
        return rel.split(separator: "/").contains(".git") ? .gitNoise : .worktree
    }

    /// `rel` is relative to a git dir: only HEAD, index, ORIG_HEAD, packed-refs and refs/** count, never *.lock.
    public static func isRelevantGitPath(_ rel: String) -> Bool {
        if rel.hasSuffix(".lock") { return false }
        return gitDirFiles.contains(rel) || rel.hasPrefix("refs/")
    }

    /// True when at least one event is something the review should react to.
    public static func hasRelevantChange(events: [String], root: String, gitDir: String, commonDir: String) async -> Bool {
        var candidates = Set<String>()
        for event in events {
            switch classify(event, root: root, gitDir: gitDir, commonDir: commonDir) {
            case .gitRelevant: return true
            case .worktree:
                if let rel = relative(trimmed(event), to: root) { candidates.insert(rel) }
            case .gitNoise, .outside: break
            }
        }
        guard !candidates.isEmpty else { return false }

        let input = Data((candidates.sorted().joined(separator: "\0") + "\0").utf8)
        let result = await GitRunner.run(["check-ignore", "-z", "--stdin"], in: root, input: input)
        // 0: some ignored, 1: none ignored. Anything else: we can't tell, so assume relevant.
        guard result.exitCode == 0 || result.exitCode == 1 else { return true }
        let ignored = Set(result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        return !candidates.isSubset(of: ignored)
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `path` relative to `base` when it is inside it (a non-empty remainder), else nil.
    private static func relative(_ path: String, to base: String) -> String? {
        let base = trimmed(base)
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
}
