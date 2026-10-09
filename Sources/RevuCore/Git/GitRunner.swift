import Foundation

/// Error carrying a message that is safe to print as `revu: <message>`.
public struct RevuError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct GitResult: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var trimmed: String { stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Thin async wrapper around `git` (read-only usage). Never throws on a non-zero exit;
/// callers decide what an exit code means.
public enum GitRunner {
    public static func run(_ arguments: [String], in directory: String? = nil, input: Data? = nil) async -> GitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(arguments, in: directory, input: input))
            }
        }
    }

    /// Runs git and throws a `RevuError` (with git's stderr) if it exits non-zero.
    public static func runChecked(_ arguments: [String], in directory: String? = nil) async throws -> GitResult {
        let result = await run(arguments, in: directory)
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RevuError("git \(arguments.first ?? "") failed: \(detail)")
        }
        return result
    }

    /// Writing to a git that already exited raises SIGPIPE, whose default action kills the process.
    /// Ignore it once, process-wide; the failed write is then just an error we already discard.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    static func runSync(_ arguments: [String], in directory: String?, input: Data? = nil) -> GitResult {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + (directory.map { ["-C", $0] } ?? []) + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = input == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return GitResult(stdout: Data(), stderr: "could not launch git: \(error.localizedDescription)", exitCode: 127)
        }

        // Feed stdin from its own thread so a large input can't deadlock against our reads.
        if let inPipe, let input {
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        // Drain stderr on another thread so a chatty child can never block on a full pipe
        // while we are busy reading stdout (and vice versa).
        let errBox = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return GitResult(
            stdout: out,
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
