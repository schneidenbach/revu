import Foundation

public struct BinaryInfo: Sendable, Equatable {
    public let oldSize: Int?
    public let newSize: Int?
}

/// Why a diff is not shown straight away.
public enum LargeReason: Sendable, Equatable {
    case changedLines(Int)
    case bytes(Int)
}

public enum LoadedDiff: Sendable, Equatable {
    case diff(FileDiff)
    case binary(BinaryInfo)
    /// Too much changed (or the file is too big); call again with `force: true` to load anyway.
    case tooLarge(LargeReason)
    /// A generated file (lock file, migration, ...); call again with `force: true` to load it.
    case generated
}

/// How much change a file may have before it needs an explicit "Load diff". File length alone never gates.
public struct LargeDiffGate: Sendable {
    public var maxChangedLines = 5_000
    public var maxBytes = 5 * 1024 * 1024
    public static let `default` = LargeDiffGate()

    public init(maxChangedLines: Int = 5_000, maxBytes: Int = 5 * 1024 * 1024) {
        self.maxChangedLines = maxChangedLines
        self.maxBytes = maxBytes
    }

    public func reason(additions: Int, deletions: Int, workingBytes: Int?, baseBytes: Int?) -> LargeReason? {
        if additions + deletions > maxChangedLines { return .changedLines(additions + deletions) }
        let biggest = max(workingBytes ?? 0, baseBytes ?? 0)
        if biggest > maxBytes { return .bytes(biggest) }
        return nil
    }
}

public enum DiffLoader {
    public static func load(
        _ file: ChangedFile, mergeBase: String, force: Bool = false, gate: LargeDiffGate = .default
    ) async throws -> LoadedDiff {
        if file.isBinary { return .binary(await binaryInfo(file, mergeBase: mergeBase)) }
        if !force {
            if file.isGenerated { return .generated }
            let workingBytes = file.status == .deleted ? nil
                : (try? FileManager.default.attributesOfItem(atPath: file.absolutePath)[.size] as? Int) ?? nil
            var baseBytes: Int?
            if workingBytes.map({ $0 <= gate.maxBytes }) ?? true, !file.isUntracked, file.status != .added {
                baseBytes = await blobSize(file, mergeBase: mergeBase)
            }
            if let reason = gate.reason(additions: file.additions, deletions: file.deletions, workingBytes: workingBytes, baseBytes: baseBytes) {
                return .tooLarge(reason)
            }
        }

        let result: GitResult
        if file.isUntracked {
            // `--no-index` exits 1 when the files differ, which is the normal case here.
            result = await GitRunner.run(
                ["diff", "--no-index", "--no-color", "--no-ext-diff", "-U1000000", "--", "/dev/null", file.path], in: file.repoRoot)
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw RevuError("git diff failed for \(file.path): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } else {
            var args = ["diff", "--no-color", "--no-ext-diff", "-M", "-U1000000", mergeBase, "--"]
            if let old = file.oldPath { args.append(old) }
            args.append(file.path)
            result = try await GitRunner.runChecked(args, in: file.repoRoot)
        }

        var diff = UnifiedDiffParser.parse(result.stdout, path: file.path, oldPath: file.oldPath)
        if diff.isBinary { return .binary(await binaryInfo(file, mergeBase: mergeBase)) }

        // A pure rename or mode change has no hunks; show the working-tree file as unchanged context
        // so both views still have something to display.
        if diff.lines.isEmpty, file.status != .deleted,
           let data = FileManager.default.contents(atPath: file.absolutePath), !data.isEmpty {
            let synthetic = UnifiedDiffParser.parse(syntheticContextDiff(data), path: file.path, oldPath: file.oldPath)
            diff.setLines(synthetic.lines, hunkStarts: synthetic.hunkStarts)
        }
        return .diff(diff)
    }

    private static func syntheticContextDiff(_ data: Data) -> Data {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var out = Data("@@ -1,\(lines.count) +1,\(lines.count) @@\n".utf8)
        for line in lines {
            out.append(0x20)
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        return out
    }

    private static func blobSize(_ file: ChangedFile, mergeBase: String) async -> Int? {
        let r = await GitRunner.run(["cat-file", "-s", "\(mergeBase):\(file.oldPath ?? file.path)"], in: file.repoRoot)
        return r.succeeded ? Int(r.trimmed) : nil
    }

    private static func binaryInfo(_ file: ChangedFile, mergeBase: String) async -> BinaryInfo {
        var oldSize: Int?
        if !file.isUntracked && file.status != .added {
            let r = await GitRunner.run(["cat-file", "-s", "\(mergeBase):\(file.oldPath ?? file.path)"], in: file.repoRoot)
            oldSize = r.succeeded ? Int(r.trimmed) : nil
        }
        var newSize: Int?
        if file.status != .deleted {
            newSize = (try? FileManager.default.attributesOfItem(atPath: file.absolutePath)[.size] as? Int) ?? nil
        }
        return BinaryInfo(oldSize: oldSize, newSize: newSize)
    }
}

/// Lets only the most recent load for a file publish its result, so a slow load that finishes after a
/// refresh (or after a newer forced load) cannot write stale data back.
public struct LoadGate: Sendable {
    private var tokens: [FileKey: Int] = [:]
    private var counter = 0

    public init() {}

    /// Starts a load for `key`; any earlier load for the same key stops being current.
    public mutating func begin(_ key: FileKey) -> Int {
        counter += 1
        tokens[key] = counter
        return counter
    }

    public func isCurrent(_ key: FileKey, token: Int) -> Bool { tokens[key] == token }

    /// Makes running loads for files of one repo stale (the repo was refreshed).
    public mutating func invalidate(repoRoot: String) {
        tokens = tokens.filter { $0.key.repoRoot != repoRoot }
    }
}
