import Foundation

public struct BaseSelection: Sendable, Hashable, Codable {
    /// The ref the review is relative to (e.g. `origin/develop`, an upstream, or `HEAD`).
    public let ref: String
    public let mergeBase: String
}

public enum BaseResolver {
    static let candidateNames = ["origin/main", "origin/master", "origin/develop", "main", "master", "develop"]
    static let defaultBranchNames: Set<String> = ["main", "master"]

    public static func resolve(for repo: RepoContext, override: String?) async throws -> BaseSelection {
        if let override, !override.isEmpty {
            guard await verify(override, in: repo.root) else {
                throw RevuError("unknown base ref '\(override)' in \(repo.displayName)")
            }
            guard let mb = await mergeBase(override, in: repo.root) else {
                throw RevuError("'\(override)' shares no history with HEAD in \(repo.displayName)")
            }
            return BaseSelection(ref: override, mergeBase: mb)
        }

        let refs = await existingRefs(in: repo.root)
        let originHeadResult = await GitRunner.run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: repo.root)
        let originHead = originHeadResult.succeeded && refs.contains("refs/remotes/\(originHeadResult.trimmed)")
            ? originHeadResult.trimmed : nil
        let upstreamResult = await GitRunner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repo.root)
        let upstream = upstreamResult.succeeded ? upstreamResult.trimmed : nil

        let defaultName = originHead.map { String($0.dropFirst("origin/".count)) }
        let onDefaultBranch: Bool = {
            guard let branch = repo.branch else { return false }
            if let defaultName { return branch == defaultName }
            return defaultBranchNames.contains(branch)
        }()

        if !onDefaultBranch {
            var ordered: [String] = []
            for name in ([originHead].compactMap { $0 } + candidateNames) where !ordered.contains(name) {
                let exists = refs.contains("refs/remotes/\(name)") || refs.contains("refs/heads/\(name)")
                if exists { ordered.append(name) }
            }
            if let branch = repo.branch {
                ordered.removeAll { $0 == branch || $0 == "origin/\(branch)" || $0 == upstream }
            }

            var best: (ref: String, mergeBase: String, count: Int)?
            for candidate in ordered {
                guard let mb = await mergeBase(candidate, in: repo.root) else { continue }
                let count = await GitRunner.run(["rev-list", "--count", "\(mb)..HEAD"], in: repo.root)
                guard count.succeeded, let n = Int(count.trimmed) else { continue }
                if best == nil || n < best!.count { best = (candidate, mb, n) }
            }
            if let best { return BaseSelection(ref: best.ref, mergeBase: best.mergeBase) }
        }

        if let upstream, let mb = await mergeBase(upstream, in: repo.root) {
            return BaseSelection(ref: upstream, mergeBase: mb)
        }
        return BaseSelection(ref: "HEAD", mergeBase: repo.headSHA)
    }

    private static func existingRefs(in root: String) async -> Set<String> {
        let result = await GitRunner.run(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], in: root)
        return Set(result.stdoutString.split(separator: "\n").map(String.init))
    }

    private static func verify(_ ref: String, in root: String) async -> Bool {
        await GitRunner.run(["rev-parse", "--verify", "-q", "\(ref)^{commit}"], in: root).succeeded
    }

    private static func mergeBase(_ ref: String, in root: String) async -> String? {
        let result = await GitRunner.run(["merge-base", ref, "HEAD"], in: root)
        return result.succeeded && !result.trimmed.isEmpty ? result.trimmed : nil
    }
}
