import Foundation

/// A throwaway directory removed when the value is cleaned up with `cleanup()`.
struct TempDir {
    let url: URL
    var path: String { url.path }

    init() throws {
        let raw = NSTemporaryDirectory() + "/revu-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        // /var/folders is a symlink to /private/var/folders; git reports the real path.
        let resolved = realpath(raw, nil).map { String(cString: $0) } ?? raw
        url = URL(fileURLWithPath: resolved, isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Minimal sync git helper for building fixtures.
struct TestRepo {
    let path: String

    /// Creates `<parent>/<name>` with `git init -b main`.
    @discardableResult
    static func make(in parent: TempDir, name: String = "repo") throws -> TestRepo {
        let path = parent.url.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let repo = TestRepo(path: path)
        repo.git("init", "-q", "-b", "main")
        return repo
    }

    @discardableResult
    func git(_ args: String..., allowFailure: Bool = false) -> String {
        run(args, allowFailure: allowFailure)
    }

    @discardableResult
    func run(_ args: [String], allowFailure: Bool = false) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Test"
        env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"
        env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try! process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(allowFailure || process.terminationStatus == 0, "git \(args) failed in \(path)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ file: String, _ content: String) {
        let url = URL(fileURLWithPath: path).appendingPathComponent(file)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: url)
    }

    func remove(_ file: String) { try? FileManager.default.removeItem(atPath: path + "/" + file) }

    func writeData(_ file: String, _ data: Data) {
        let url = URL(fileURLWithPath: path).appendingPathComponent(file)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
    }

    /// Writes files, stages everything, and commits.
    @discardableResult
    func commit(_ message: String, _ files: [String: String] = [:]) -> String {
        for (file, content) in files { write(file, content) }
        git("add", "-A")
        git("commit", "-q", "-m", message, "--allow-empty")
        return git("rev-parse", "HEAD")
    }
}

// Test files import Testing but not Foundation: with a Command Line Tools-only toolchain the
// Testing/Foundation cross-import overlay is missing, so a file importing both fails to compile.
// Foundation types the tests need are re-exposed here instead.
typealias Data = Foundation.Data
typealias UUID = Foundation.UUID

@testable import RevuCore

/// Builds a full-context single-hunk diff from lines prefixed with " ", "-" or "+".
func makeDiff(_ spec: String..., path: String = "f.txt") -> FileDiff {
    makeDiff(spec, path: path)
}

func makeDiff(_ spec: [String], path: String = "f.txt") -> FileDiff {
    let old = spec.filter { $0.hasPrefix(" ") || $0.hasPrefix("-") }.count
    let new = spec.filter { $0.hasPrefix(" ") || $0.hasPrefix("+") }.count
    let text = (["@@ -1,\(old) +1,\(new) @@"] + spec).joined(separator: "\n") + "\n"
    return UnifiedDiffParser.parse(text, path: path)
}

func joinLines(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

extension TempDir {
    func write(_ relative: String, _ content: String) throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    func read(_ relative: String) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A local-time date, matching what DateFormatter renders in file names.
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
}

// Swift Testing also declares a `Comment`; prefer ours inside this test module.
typealias Comment = RevuCore.Comment

@testable import revu

/// A temp repo with one changed file, wrapped in an AppState whose drafts and archive live in the temp dir.
@MainActor
struct Fixture {
    let tmp: TempDir
    let repo: TestRepo
    let state: AppState
    var path = "a.txt"
    var key: FileKey { FileKey(repoRoot: repo.path, path: path) }

    /// Base commit has `base`; the working tree has `work`. Waits until the selected file's diff is loaded.
    static func make(
        path: String = "a.txt", base: String = "one\ntwo\nthree\nfour\nfive\n", work: String = "one\nTWO\nthree\nfive\nsix\n",
        refreshDelay: TimeInterval = 0.4, retryDelay: TimeInterval = 1.5
    ) async throws -> Fixture {
        let tmp = try TempDir()
        let repo = try TestRepo.make(in: tmp)
        repo.commit("base", [path: base])
        repo.write(path, work)
        let state = try await makeState(tmp: tmp, repo: repo, refreshDelay: refreshDelay, retryDelay: retryDelay)
        var fixture = Fixture(tmp: tmp, repo: repo, state: state)
        fixture.path = path
        try await fixture.waitForDiff()
        return fixture
    }

    private static func makeState(tmp: TempDir, repo: TestRepo, refreshDelay: TimeInterval = 0.4, retryDelay: TimeInterval = 1.5) async throws -> AppState {
        let snapshots = try await RepoSnapshot.loadAll(targets: [RepoTarget(directory: repo.path)], globalBase: "HEAD")
        return AppState(
            snapshots: snapshots, options: Options(targets: [RepoTarget(directory: repo.path)]),
            drafts: DraftStore(directory: tmp.url.appendingPathComponent("drafts")),
            archive: ReviewArchive(directory: tmp.url.appendingPathComponent("reviews")),
            refreshDelay: refreshDelay, retryDelay: retryDelay)
    }

    /// A new AppState on the same repos and drafts directory, like running `revu` again.
    func relaunch() async throws -> AppState {
        try await Fixture.makeState(tmp: tmp, repo: repo)
    }

    /// Hides the repo's `.git` so reloading it fails, and puts it back.
    func breakRepo() throws { try FileManager.default.moveItem(atPath: repo.path + "/.git", toPath: repo.path + "/.git-off") }
    func repairRepo() throws { try FileManager.default.moveItem(atPath: repo.path + "/.git-off", toPath: repo.path + "/.git") }

    func waitForDiff() async throws {
        for _ in 0..<200 {
            if state.loadedFile(key) != nil { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw RevuError("diff did not load")
    }
}

/// Polls `condition` for up to `seconds`.
@MainActor
func eventually(seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}


/// The app ignores SIGPIPE; so must the test process, or a broken pipe would kill the test runner.
func ignoreSIGPIPE() { signal(SIGPIPE, SIG_IGN) }
