import Foundation

public struct RepoContext: Sendable, Hashable, Codable {
    public let root: String
    public let gitDir: String
    public let commonDir: String
    public let isWorktree: Bool
    /// nil when HEAD is detached.
    public let branch: String?
    public let headSHA: String
    public let displayName: String

    public init(root: String, gitDir: String, commonDir: String, branch: String?, headSHA: String) {
        self.root = root
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.isWorktree = gitDir != commonDir
        self.branch = branch
        self.headSHA = headSHA
        let folder = URL(fileURLWithPath: root).lastPathComponent
        if gitDir != commonDir {
            let main = URL(fileURLWithPath: commonDir).deletingLastPathComponent().lastPathComponent
            self.displayName = "\(main) ⎇ \(folder)"
        } else {
            self.displayName = folder
        }
    }
}

public enum RepoResolver {
    /// Resolves a user-supplied directory (relative paths are taken from `cwd`) to the enclosing repo.
    public static func resolve(directory: String, cwd: String = FileManager.default.currentDirectoryPath) async throws -> RepoContext {
        let path = absolutePath(directory, cwd: cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw RevuError("\(directory) is not a directory")
        }

        let paths = await GitRunner.run(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: path)
        let lines = paths.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard paths.succeeded, lines.count == 3 else {
            throw RevuError("\(directory) is not inside a git repository")
        }

        let head = await GitRunner.run(["rev-parse", "--verify", "-q", "HEAD"], in: path)
        guard head.succeeded else {
            throw RevuError("\(directory) has no commits yet")
        }
        let branchResult = await GitRunner.run(["symbolic-ref", "-q", "--short", "HEAD"], in: path)
        let branch = branchResult.succeeded ? branchResult.trimmed : nil

        return RepoContext(
            root: lines[0], gitDir: lines[1], commonDir: lines[2],
            branch: branch?.isEmpty == true ? nil : branch, headSHA: head.trimmed)
    }

    public static func absolutePath(_ directory: String, cwd: String) -> String {
        let joined = directory.hasPrefix("/") ? directory : cwd + "/" + directory
        return URL(fileURLWithPath: joined).standardizedFileURL.path
    }
}
