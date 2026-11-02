import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Text plus routing metadata only; no audio field or opaque payload storage.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public let segmentID: String
    public let targetID: String
    public let text: String
    public let createdAt: Int64
    public init(segmentID: String, targetID: String, text: String, createdAt: Int64) {
        self.segmentID = segmentID; self.targetID = targetID
        self.text = text; self.createdAt = createdAt
    }
}

public protocol HistoryStore: Sendable {
    func append(_ entry: HistoryEntry, now: Int64) async throws
    func entries(now: Int64) async throws -> [HistoryEntry]
    func purge(now: Int64) async throws
}

private func retained(_ entries: [HistoryEntry], now: Int64) -> [HistoryEntry] {
    // Reject future entries too, avoiding indefinite retention after a bad clock.
    entries.filter { $0.createdAt >= 0 && $0.createdAt <= now && now - $0.createdAt < 604_800_000 }
}

public actor InMemoryHistoryStore: HistoryStore {
    private var stored: [HistoryEntry] = []
    public init() {}
    public func append(_ entry: HistoryEntry, now: Int64) {
        stored = retained(stored + [entry], now: now)
    }
    public func entries(now: Int64) -> [HistoryEntry] {
        purge(now: now)
        return stored
    }
    public func purge(now: Int64) { stored = retained(stored, now: now) }
}

/// One actor owns one file. Call purge at app startup and from a background timer.
/// Apple file protection and backup exclusions belong to the UI storage adapter.
public actor FileHistoryStore: HistoryStore {
    private let url: URL
    private var stored: [HistoryEntry]
    public init(url: URL, now: Int64) throws {
        self.url = url
        let pending = Self.pendingURL(for: url)
        // A previous process may have stopped between write and rename. One
        // actor owns this destination, so its pending file can be removed on open.
        if FileManager.default.fileExists(atPath: pending.path) { try FileManager.default.removeItem(at: pending) }
        if FileManager.default.fileExists(atPath: url.path) {
            stored = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: url))
        } else { stored = [] }
        stored = retained(stored, now: now)
        try Self.write(stored, to: url)
    }
    private static func pendingURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".history-pending")
    }
    private static func write(_ entries: [HistoryEntry], to url: URL) throws {
        let data = try JSONEncoder().encode(entries)
        let temporary = pendingURL(for: url)
        // Private from creation, including the interval before atomic replacement.
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    public func append(_ entry: HistoryEntry, now: Int64) throws {
        let next = retained(stored + [entry], now: now)
        try Self.write(next, to: url)
        stored = next
    }
    public func entries(now: Int64) throws -> [HistoryEntry] {
        try purge(now: now)
        return stored
    }
    public func purge(now: Int64) throws {
        let next = retained(stored, now: now)
        try Self.write(next, to: url)
        stored = next
    }
}
