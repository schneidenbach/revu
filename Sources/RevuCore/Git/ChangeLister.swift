import Foundation

/// Identifies one file in one repo; used for selection, viewed state and cache keys.
public struct FileKey: Hashable, Codable, Sendable {
    public let repoRoot: String
    public let path: String
    public init(repoRoot: String, path: String) {
        self.repoRoot = repoRoot
        self.path = path
    }
}

public enum ChangeStatus: String, Codable, Sendable {
    case added = "A", modified = "M", deleted = "D", renamed = "R", typeChanged = "T"
}

public struct ChangedFile: Hashable, Sendable, Identifiable {
    public let repoRoot: String
    public let path: String
    public let oldPath: String?
    public let status: ChangeStatus
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
    public let isUntracked: Bool
    /// Lock files, minified output, EF Core migrations, ...: loaded collapsed.
    public var isGenerated = false

    public var id: FileKey { key }
    public var key: FileKey { FileKey(repoRoot: repoRoot, path: path) }
    public var absolutePath: String { repoRoot + "/" + path }
}

public enum ChangeLister {
    /// Everything between `mergeBase` and the working tree (committed, staged, unstaged) plus untracked files.
    public static func list(in repo: RepoContext, mergeBase: String) async throws -> [ChangedFile] {
        async let statuses = GitRunner.runChecked(["diff", "--no-color", "--no-ext-diff", "--name-status", "-z", "-M", mergeBase, "--"], in: repo.root)
        async let numstat = GitRunner.runChecked(["diff", "--no-color", "--no-ext-diff", "--numstat", "-z", "-M", mergeBase, "--"], in: repo.root)
        async let untracked = GitRunner.runChecked(["ls-files", "--others", "--exclude-standard", "-z"], in: repo.root)

        let counts = parseNumstat(try await numstat.stdout)
        var files = parseNameStatus(try await statuses.stdout, root: repo.root, counts: counts)

        for relative in splitNUL(try await untracked.stdout) {
            guard let info = untrackedInfo(root: repo.root, path: relative) else { continue }
            files.append(ChangedFile(
                repoRoot: repo.root, path: relative, oldPath: nil, status: .added,
                additions: info.lines, deletions: 0, isBinary: info.isBinary, isUntracked: true))
        }
        let generated = await GeneratedFiles.detect(paths: files.map(\.path), in: repo.root)
        for i in files.indices where generated.contains(files[i].path) { files[i].isGenerated = true }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Parsing

    struct Counts { var additions: Int; var deletions: Int; var isBinary: Bool }

    static func splitNUL(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `-z --numstat`: `add\tdel\tpath\0`, or for renames `add\tdel\t\0old\0new\0`. Binary files report `-`.
    static func parseNumstat(_ data: Data) -> [String: Counts] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [String: Counts] = [:]
        var i = 0
        while i < tokens.count {
            let parts = tokens[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty, i + 1 < tokens.count {
                path = tokens[i + 1]
                i += 2
            }
            let binary = parts[0] == "-"
            result[path] = Counts(additions: Int(parts[0]) ?? 0, deletions: Int(parts[1]) ?? 0, isBinary: binary)
        }
        return result
    }

    /// `-z --name-status`: `M\0path\0`, `R100\0old\0new\0`.
    static func parseNameStatus(_ data: Data, root: String, counts: [String: Counts]) -> [ChangedFile] {
        let tokens = splitNUL(data)
        var files: [ChangedFile] = []
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let letter = code.first else { continue }
            let takesTwoPaths = letter == "R" || letter == "C"
            guard i < tokens.count, !takesTwoPaths || i + 1 < tokens.count else { break }
            let first = tokens[i]
            let second = takesTwoPaths ? tokens[i + 1] : nil
            i += takesTwoPaths ? 2 : 1

            let path = second ?? first
            let status: ChangeStatus
            switch letter {
            case "A", "C": status = .added
            case "D": status = .deleted
            case "R": status = .renamed
            case "T": status = .typeChanged
            default: status = .modified
            }
            let c = counts[path]
            files.append(ChangedFile(
                repoRoot: root, path: path, oldPath: letter == "R" ? first : nil, status: status,
                additions: c?.additions ?? 0, deletions: c?.deletions ?? 0,
                isBinary: c?.isBinary ?? false, isUntracked: false))
        }
        return files
    }

    static func untrackedInfo(root: String, path: String) -> (lines: Int, isBinary: Bool)? {
        let url = URL(fileURLWithPath: root + "/" + path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.prefix(8192).contains(0) { return (0, true) }
        return (lineCount(data), false)
    }

    static func lineCount(_ data: Data) -> Int {
        guard let last = data.last else { return 0 }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return last == 0x0A ? newlines : newlines + 1
    }
}
