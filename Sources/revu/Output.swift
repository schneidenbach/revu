import Foundation

/// The only places revu writes to stdout/stderr, so a closed pipe can never crash it.
enum Output {
    /// `FileHandle.write(_:)` raises an uncatchable Objective-C exception on EPIPE; this just gives up quietly.
    static func write(_ data: Data, to handle: FileHandle) {
        try? handle.write(contentsOf: data)
    }

    static func warn(_ message: String) {
        write(Data("revu: \(message)\n".utf8), to: .standardError)
    }

    /// Writes the result and terminates the process; this is the only way the review leaves the app.
    static func finish(code: Int32, stdout: String? = nil, stderr: String? = nil) -> Never {
        if let stdout { write(Data((stdout.hasSuffix("\n") ? stdout : stdout + "\n").utf8), to: .standardOutput) }
        if let stderr { write(Data((stderr + "\n").utf8), to: .standardError) }
        exit(code)
    }
}
