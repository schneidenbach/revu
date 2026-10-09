import Foundation

/// A directory argument plus its optional per-directory base override (`dir=REF`).
public struct RepoTarget: Sendable, Equatable {
    public let directory: String
    public let baseOverride: String?
    public init(directory: String, baseOverride: String? = nil) {
        self.directory = directory
        self.baseOverride = baseOverride
    }
}

/// Everything the UI needs to know about one repo: identity, chosen base, and changed files.
public struct RepoSnapshot: Sendable, Identifiable {
    public let context: RepoContext
    public let base: BaseSelection
    public let files: [ChangedFile]
    /// The base the user asked for (`--base` or `dir=REF`); nil when auto-detected. Reused by Refresh.
    public let requestedBase: String?
    public var id: String { context.root }

    /// Resolves all targets concurrently. Targets that resolve to the same repo root are merged
    /// (first one wins). Throws the first error in argument order, regardless of which finished first.
    public static func loadAll(targets: [RepoTarget], globalBase: String?, cwd: String = FileManager.default.currentDirectoryPath) async throws -> [RepoSnapshot] {
        let contexts = try await inArgumentOrder(count: targets.count) { i in
            try await RepoResolver.resolve(directory: targets[i].directory, cwd: cwd)
        }

        var seen = Set<String>()
        var pending: [(RepoContext, String?)] = []
        for (i, context) in contexts.enumerated() where seen.insert(context.root).inserted {
            pending.append((context, targets[i].baseOverride ?? globalBase))
        }
        let unique = pending

        return try await inArgumentOrder(count: unique.count) { i in
            try await load(unique[i].0, requestedBase: unique[i].1)
        }
    }

    /// Runs `work(0..<count)` concurrently; returns results in index order or throws the lowest-index error.
    private static func inArgumentOrder<T: Sendable>(
        count: Int, _ work: @escaping @Sendable (Int) async throws -> T
    ) async throws -> [T] {
        let results = await withTaskGroup(of: (Int, Result<T, Error>).self) { group in
            for i in 0..<count {
                group.addTask {
                    do { return (i, .success(try await work(i))) } catch { return (i, .failure(error)) }
                }
            }
            var collected: [(Int, Result<T, Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return try results.map { try $0.get() }
    }

    /// Re-resolves the branch, base and file list for a repo (used by Refresh).
    public func reloaded() async throws -> RepoSnapshot {
        try await Self.load(context, requestedBase: requestedBase)
    }

    private static func load(_ context: RepoContext, requestedBase: String?) async throws -> RepoSnapshot {
        let fresh = try await RepoResolver.resolve(directory: context.root)
        let base = try await BaseResolver.resolve(for: fresh, override: requestedBase)
        let files = try await ChangeLister.list(in: fresh, mergeBase: base.mergeBase)
        return RepoSnapshot(context: fresh, base: base, files: files, requestedBase: requestedBase)
    }
}
