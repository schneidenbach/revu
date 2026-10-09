import Foundation
import RevuCore

/// Live refresh: file watching, debounced and retried reloads, and the Viewed re-check that follows them.
extension AppState {
    /// Manual refresh (⌘R): everything, as soon as no other refresh is running.
    func refresh() {
        dirtyRoots.formUnion(repos.map(\.context.root))
        retry.reset()
        request(after: 0)
    }

    /// Called by a file watcher when something relevant changed in `root`.
    func externalChange(in root: String) {
        dirtyRoots.insert(root)
        retry.reset()
        request(after: coalescer.delay)
    }

    func startWatching() {
        watchers = repos.map { snapshot in
            RepoWatcher(context: snapshot.context) { [weak self] root in self?.externalChange(in: root) }
        }
    }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Debounced, single-flight scheduling on top of `RefreshCoalescer`.
    func request(after delay: TimeInterval) {
        coalescer.noteEvent(at: Self.now() + delay - coalescer.delay)
        if delay == 0 { manualRequested = true }
        guard refreshDriver == nil else { return }
        refreshDriver = Task {
            while let deadline = coalescer.nextDeadline {
                let wait = deadline - Self.now()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard coalescer.poll(at: Self.now()) else { continue }
                let roots = dirtyRoots
                dirtyRoots = []
                let automatic = !manualRequested
                manualRequested = false
                let succeeded = await performRefresh(roots: roots, automatic: automatic)
                coalescer.finish()
                if succeeded {
                    retry.recordSuccess()
                } else {
                    // Keep the work: a later event or the retry below will pick these roots up again.
                    dirtyRoots.formUnion(roots)
                    if let wait = retry.recordFailure() { request(after: wait) }
                }
            }
            refreshDriver = nil
        }
    }

    /// Reloads the given repos in place: keeps selection, mode, expansion and comments, refreshes the
    /// selected file's diff without flashing, and invalidates the other cached diffs.
    @discardableResult
    func performRefresh(roots: Set<String>, automatic: Bool) async -> Bool {
        refreshAttempts += 1
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }
        do {
            var fresh = repos
            for (i, snapshot) in repos.enumerated() where roots.contains(snapshot.context.root) {
                fresh[i] = try await snapshot.reloaded()
            }
            repos = fresh
            for root in roots {
                loadGate.invalidate(repoRoot: root)
                for key in diffStates.keys where key.repoRoot == root && key != selection {
                    // A load that was still running was just invalidated; anything finished is kept
                    // (with its expansion state) and reloaded the next time the file is selected.
                    if case .loading = diffStates[key] { diffStates[key] = nil } else { staleKeys.insert(key) }
                }
            }
            staleKeys = staleKeys.filter { file($0) != nil }
            for key in diffStates.keys where file(key) == nil && key != selection { diffStates[key] = nil }
            if selection.flatMap(file) == nil { selection = allFiles.first?.key }
            if let selection { ensureLoaded(selection, keepCurrent: true) }

            await recheckViewed()
            if automatic { flashUpdatedToast() }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Un-views files whose diff changed since they were viewed; fills in missing fingerprints.
    func recheckViewed() async {
        guard !viewed.isEmpty else { return }
        let snapshot = viewed
        let outcome = await ViewedTracker.recheck(
            viewed: snapshot, files: repos.flatMap(\.files),
            mergeBases: Dictionary(uniqueKeysWithValues: repos.map { ($0.context.root, $0.base.mergeBase) }))
        // Apply only if the user hasn't touched that file's mark while we were computing.
        for key in outcome.changed where viewed[key] == snapshot[key] {
            viewed[key] = nil
            changedSinceViewed.insert(key)
        }
        for (key, fingerprint) in outcome.filled where viewed[key] == ViewedTracker.unknown { viewed[key] = fingerprint }
        if !outcome.changed.isEmpty || !outcome.filled.isEmpty { scheduleDraftSave() }
    }

    func flashUpdatedToast() {
        showUpdatedToast = true
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showUpdatedToast = false
        }
    }
}
