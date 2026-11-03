import Foundation
import Core
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Text-only store with explicit deletion. Apple host supplies a protected, backup-excluded URL.
public actor AppHistoryStore: HistoryStore {
    private var values: [HistoryEntry]
    private let url: URL?
    public init(url: URL? = nil, now: Int64) throws {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            values = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: url))
        } else { values = [] }
        values = Self.retained(values, now: now)
        if let url { try Self.persist(values, url: url) }
    }
    private static func retained(_ items: [HistoryEntry], now: Int64) -> [HistoryEntry] {
        items.filter { $0.createdAt >= 0 && $0.createdAt <= now && now - $0.createdAt < 604_800_000 }
    }
    private static func persist(_ items: [HistoryEntry], url: URL) throws {
        let pending = url.appendingPathExtension("pending")
        try? FileManager.default.removeItem(at: pending)
        let descriptor = open(pending.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: pending) }
        try handle.write(contentsOf: JSONEncoder().encode(items)); try handle.synchronize()
        guard rename(pending.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func save(_ items: [HistoryEntry]) throws {
        if let url { try Self.persist(items, url: url) }
        values = items
    }
    public func append(_ entry: HistoryEntry, now: Int64) throws { try save(Self.retained(values + [entry], now: now)) }
    public func entries(now: Int64) throws -> [HistoryEntry] { try purge(now: now); return values }
    public func purge(now: Int64) throws { try save(Self.retained(values, now: now)) }
    public func delete(id: String, now: Int64) throws { try save(Self.retained(values.filter { $0.segmentID != id }, now: now)) }
}
