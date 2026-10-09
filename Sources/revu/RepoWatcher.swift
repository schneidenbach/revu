import CoreServices
import Foundation
import RevuCore

/// Watches one repo (worktree plus git dir) with FSEvents and reports when something relevant changed.
/// Noise (ignored build output, git internals) is filtered by `WatchFilter` before `onChange` is called.
/// A watcher lives as long as the process, so its stream is never torn down.
@MainActor
final class RepoWatcher {
    private let context: RepoContext
    private let onChange: @MainActor (String) -> Void
    private var stream: FSEventStreamRef?

    init(context: RepoContext, onChange: @escaping @MainActor (String) -> Void) {
        self.context = context
        self.onChange = onChange
        start()
    }

    /// The worktree root plus any git dir not already inside it (linked worktrees keep theirs elsewhere).
    private static func watchedPaths(for context: RepoContext) -> [String] {
        var paths = [context.root]
        for dir in [context.gitDir, context.commonDir] where !paths.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) {
            paths.append(dir)
        }
        return paths
    }

    private func start() {
        let box = Unmanaged.passRetained(CallbackBox { [weak self] paths in
            Task { @MainActor in await self?.handle(paths) }
        })
        var streamContext = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<CallbackBox>.fromOpaque(info).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().handler(Array(paths.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            nil, callback, &streamContext, Self.watchedPaths(for: context) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "revu.fsevents.\(context.displayName)", qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handle(_ paths: [String]) async {
        let relevant = await WatchFilter.hasRelevantChange(
            events: paths, root: context.root, gitDir: context.gitDir, commonDir: context.commonDir)
        if relevant { onChange(context.root) }
    }
}

private final class CallbackBox: @unchecked Sendable {
    let handler: @Sendable ([String]) -> Void
    init(_ handler: @escaping @Sendable ([String]) -> Void) { self.handler = handler }
}
