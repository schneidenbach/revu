import Foundation

/// Decides which changed files are "generated" (lock files, minified output, EF Core migrations, ...)
/// and should load collapsed, the way GitHub collapses them.
public enum GeneratedFiles {
    static let exactNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "cargo.lock", "gemfile.lock",
        "podfile.lock", "composer.lock", "poetry.lock", "go.sum", "packages.lock.json",
    ]
    static let suffixes = [".min.js", ".min.css", ".map", ".designer.cs", "modelsnapshot.cs", ".g.cs"]

    /// Built-in patterns, matched case-insensitively against the file name.
    public static func matchesBuiltInPattern(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return exactNames.contains(name) || suffixes.contains { name.hasSuffix($0) } || name.contains(".generated.")
    }

    /// What `.gitattributes` says about one path.
    public struct Attributes: Equatable, Sendable {
        /// `linguist-generated`: true when set/true, false when unset/false, nil when unspecified.
        public var linguistGenerated: Bool?
        /// `-diff`: git treats the file as not diffable.
        public var diffUnset: Bool
    }

    /// Parses `git check-attr -z linguist-generated diff` output: `path NUL attribute NUL value NUL` triples.
    public static func parseCheckAttr(_ data: Data) -> [String: Attributes] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [String: Attributes] = [:]
        var i = 0
        while i + 2 < tokens.count {
            let path = tokens[i], attribute = tokens[i + 1], value = tokens[i + 2]
            i += 3
            var entry = result[path] ?? Attributes(linguistGenerated: nil, diffUnset: false)
            switch attribute {
            case "linguist-generated":
                switch value {
                case "set", "true": entry.linguistGenerated = true
                case "unset", "false": entry.linguistGenerated = false
                default: break
                }
            case "diff":
                entry.diffUnset = value == "unset"
            default: break
            }
            result[path] = entry
        }
        return result
    }

    /// Explicit attributes win over built-in patterns (`-linguist-generated` opts a file back in).
    public static func isGenerated(path: String, attributes: Attributes?) -> Bool {
        if let explicit = attributes?.linguistGenerated { return explicit }
        if attributes?.diffUnset == true { return true }
        return matchesBuiltInPattern(path)
    }

    /// One `git check-attr` call for all paths of a repo, combined with the built-in patterns.
    public static func detect(paths: [String], in repoRoot: String) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let input = Data(paths.joined(separator: "\0").utf8 + [0])
        let result = await GitRunner.run(["check-attr", "-z", "--stdin", "linguist-generated", "diff"], in: repoRoot, input: input)
        let attributes = result.succeeded ? parseCheckAttr(result.stdout) : [:]
        return Set(paths.filter { isGenerated(path: $0, attributes: attributes[$0]) })
    }
}
