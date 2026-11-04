import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Text plus routing metadata only; no audio field or opaque payload storage.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public let accountID: String?
    public let segmentID: String
    public let targetID: String
    public let text: String
    public let createdAt: Int64
    public init(segmentID: String, targetID: String, text: String, createdAt: Int64, accountID: String? = nil) {
        self.accountID = accountID
        self.segmentID = segmentID; self.targetID = targetID
        self.text = text; self.createdAt = createdAt
    }
}

/// Versioned local envelope. The trusted installation pin supplies legacy ownership.
public struct AccountRecordEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public let version: Int
    public let accountID: String
    public let records: Value
    public init(accountID: String, records: Value) throws {
        try RecordAccount.validate(accountID)
        version = 2; self.accountID = accountID; self.records = records
    }
    public func validate(account: String) throws {
        try RecordAccount.validate(account)
        guard version == 2, accountID == account else { throw CoreError.wrongAccount }
    }
}
public enum RecordAccount {
    public static func validate(_ account: String) throws {
        guard !account.isEmpty, account != "*", account.unicodeScalars.count <= 128,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CoreError.wrongAccount }
    }
    public static func bind(_ entry: HistoryEntry, to account: String, legacy: Bool = true) throws -> HistoryEntry {
        try validate(account)
        guard entry.accountID == account || (legacy && entry.accountID == nil) else { throw CoreError.wrongAccount }
        return HistoryEntry(segmentID: entry.segmentID, targetID: entry.targetID, text: entry.text, createdAt: entry.createdAt, accountID: account)
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
    public let accountID: String
    public init(url: URL, now: Int64, accountID: String = "owner-local") throws {
        try RecordAccount.validate(accountID)
        self.accountID = accountID; self.url = url
        let pending = Self.pendingURL(for: url)
        // A previous process may have stopped between write and rename. One
        // actor owns this destination, so its pending file can be removed on open.
        if FileManager.default.fileExists(atPath: pending.path) { try FileManager.default.removeItem(at: pending) }
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            if try JSONSerialization.jsonObject(with: bytes) is [Any] {
                stored = try JSONDecoder().decode([HistoryEntry].self, from: bytes).map { try RecordAccount.bind($0, to: accountID) }
            } else {
                let envelope = try JSONDecoder().decode(AccountRecordEnvelope<[HistoryEntry]>.self, from: bytes)
                try envelope.validate(account: accountID)
                stored = try envelope.records.map { try RecordAccount.bind($0, to: accountID, legacy: false) }
            }
        } else { stored = [] }
        stored = retained(stored, now: now)
        try Self.write(stored, to: url, accountID: accountID)
    }
    private static func pendingURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".history-pending")
    }
    private static func write(_ entries: [HistoryEntry], to url: URL, accountID: String) throws {
        let data = try JSONEncoder().encode(AccountRecordEnvelope(accountID: accountID, records: entries))
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
        let next = retained(stored + [try RecordAccount.bind(entry, to: accountID)], now: now)
        try Self.write(next, to: url, accountID: accountID)
        stored = next
    }
    public func entries(now: Int64) throws -> [HistoryEntry] {
        try purge(now: now)
        return stored
    }
    public func purge(now: Int64) throws {
        let next = retained(stored, now: now)
        try Self.write(next, to: url, accountID: accountID)
        stored = next
    }
}
