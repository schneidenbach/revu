import CryptoKit
import Foundation

/// Remembers *what* was viewed, so a file whose diff changes afterwards can be un-viewed automatically.
public enum ViewedTracker {
    /// Stored for a viewed file whose fingerprint has not been computed yet (e.g. an older draft).
    public static let unknown = ""

    /// SHA-256 over the merge-base and the file's normal-context diff. Touching a file without changing
    /// its content, or committing something that leaves this diff alone, keeps the fingerprint.
    public static func fingerprint(of file: ChangedFile, mergeBase: String) async -> String? {
        let result: GitResult
        if file.isUntracked {
            result = await GitRunner.run(
                ["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", file.path], in: file.repoRoot)
            guard result.exitCode == 0 || result.exitCode == 1 else { return nil }
        } else {
            var args = ["diff", "--no-color", "--no-ext-diff", "-M", mergeBase, "--"]
            if let old = file.oldPath { args.append(old) }
            args.append(file.path)
            result = await GitRunner.run(args, in: file.repoRoot)
            guard result.succeeded else { return nil }
        }
        var data = Data(mergeBase.utf8)
        data.append(0)
        data.append(result.stdout)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public struct Outcome: Equatable, Sendable {
        /// Viewed files whose diff changed since they were viewed.
        public var changed: Set<FileKey> = []
        /// Fingerprints for viewed files that had none yet.
        public var filled: [FileKey: String] = [:]
    }

    /// Recomputes fingerprints (concurrently) for viewed files that are still in `files`.
    /// - Parameter mergeBases: merge-base per repo root.
    public static func recheck(viewed: [FileKey: String], files: [ChangedFile], mergeBases: [String: String]) async -> Outcome {
        let byKey = Dictionary(files.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = viewed.compactMap { key, stored -> (ChangedFile, String, String)? in
            guard let file = byKey[key], let mergeBase = mergeBases[key.repoRoot] else { return nil }
            return (file, mergeBase, stored)
        }
        return await withTaskGroup(of: (FileKey, String, String?).self) { group in
            for (file, mergeBase, stored) in targets {
                group.addTask { (file.key, stored, await fingerprint(of: file, mergeBase: mergeBase)) }
            }
            var outcome = Outcome()
            for await (key, stored, current) in group {
                guard let current else { continue }
                if stored == unknown { outcome.filled[key] = current }
                else if stored != current { outcome.changed.insert(key) }
            }
            return outcome
        }
    }
}
