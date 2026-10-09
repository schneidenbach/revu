import Foundation

public struct Options: Equatable, Sendable {
    public var base: String?
    public var json = false
    public var output: String?
    public var title: String?
    public var targets: [RepoTarget] = []
}

public enum ParsedArguments: Equatable, Sendable {
    case run(Options)
    case help
    case version
    case failure(String)
}

public enum Arguments {
    public static let usage = """
        usage: revu [--base REF] [--json] [--output FILE] [--title TEXT] <dir> [<dir> ...]

        Opens a review window for the changes in one or more git repos/worktrees (merge-base with the
        base branch -> working tree, including untracked files), blocks until the review is submitted
        or the window is closed, then prints the review to stdout.

        options:
          --base REF       compare against REF in every repo (default: detected per repo)
          --json           print JSON instead of Markdown
          --output FILE    also write the review (in the chosen format) to FILE
          --title TEXT     window title
          --version        print the version
          -h, --help       show this help

        A directory may carry its own base: revu ../Data=origin/develop

        exit status: 0 submitted, 1 usage or git error, 2 closed without submitting
        """

    /// - Parameter arguments: argv without the program name.
    /// - Parameter isDirectory: used to tell `dir=REF` from a directory that really contains `=`.
    public static func parse(_ arguments: [String], isDirectory: (String) -> Bool = defaultIsDirectory) -> ParsedArguments {
        var options = Options()
        var i = 0
        var onlyPositionals = false

        func value(for flag: String, inline: String?) -> String? {
            if let inline { return inline }
            guard i + 1 < arguments.count else { return nil }
            i += 1
            return arguments[i]
        }

        while i < arguments.count {
            let arg = arguments[i]
            if onlyPositionals || !arg.hasPrefix("-") || arg == "-" {
                options.targets.append(target(arg, isDirectory: isDirectory))
            } else if arg == "--" {
                onlyPositionals = true
            } else if arg == "-h" || arg == "--help" {
                return .help
            } else if arg == "--version" {
                return .version
            } else if arg == "--json" {
                options.json = true
            } else if arg.hasPrefix("--") {
                let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                let inline = parts.count > 1 ? String(parts[1]) : nil
                switch name {
                case "--base", "--output", "--title":
                    guard let v = value(for: name, inline: inline), !v.isEmpty else {
                        return .failure("\(name) needs a value")
                    }
                    switch name {
                    case "--base": options.base = v
                    case "--output": options.output = v
                    default: options.title = v
                    }
                default:
                    return .failure("unknown option \(name)")
                }
            } else {
                return .failure("unknown option \(arg)")
            }
            i += 1
        }

        guard !options.targets.isEmpty else { return .failure("no directories given") }
        return .run(options)
    }

    private static func target(_ arg: String, isDirectory: (String) -> Bool) -> RepoTarget {
        if !isDirectory(arg), let eq = arg.lastIndex(of: "=") {
            let dir = String(arg[..<eq]), ref = String(arg[arg.index(after: eq)...])
            if !dir.isEmpty, !ref.isEmpty { return RepoTarget(directory: dir, baseOverride: ref) }
        }
        return RepoTarget(directory: arg)
    }

    public static func defaultIsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
