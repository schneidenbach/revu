import CryptoKit
import Foundation

public enum AppSupport {
    /// `~/Library/Application Support/revu`
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("revu", isDirectory: true)
    }
}

/// Autosaved review drafts, one file per set of repo roots.
public struct DraftStore: Sendable {
    public let directory: URL

    public init(directory: URL = AppSupport.directory.appendingPathComponent("drafts", isDirectory: true)) {
        self.directory = directory
    }

    public static func key(for roots: [String]) -> String {
        let digest = SHA256.hash(data: Data(roots.sorted().joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func url(for roots: [String]) -> URL {
        directory.appendingPathComponent(Self.key(for: roots) + ".json")
    }

    public func load(roots: [String]) -> ReviewDraft? {
        guard let data = try? Data(contentsOf: url(for: roots)) else { return nil }
        return try? JSONDecoder().decode(ReviewDraft.self, from: data)
    }

    /// Saves the draft; an empty draft removes the file instead.
    public func save(_ draft: ReviewDraft, roots: [String]) throws {
        if draft.isEmpty { return delete(roots: roots) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(draft).write(to: url(for: roots), options: .atomic)
    }

    public func delete(roots: [String]) {
        try? FileManager.default.removeItem(at: url(for: roots))
    }
}

/// Every submitted review is also kept on disk, so it can be recovered if the agent session was lost.
public struct ReviewArchive: Sendable {
    public let directory: URL

    public init(directory: URL = AppSupport.directory.appendingPathComponent("reviews", isDirectory: true)) {
        self.directory = directory
    }

    /// Writes `<yyyyMMdd-HHmmss>.md` and `.json`, returning the markdown file's URL.
    @discardableResult
    public func save(markdown: String, json: String, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = formatter.string(from: date)
        let mdURL = directory.appendingPathComponent(stem + ".md")
        try Data(markdown.utf8).write(to: mdURL, options: .atomic)
        try Data(json.utf8).write(to: directory.appendingPathComponent(stem + ".json"), options: .atomic)
        return mdURL
    }
}
