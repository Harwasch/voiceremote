import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum PolicyError: Error { case invalid, auditUnavailable, tampered, locked, clock }

public struct AuditCheckpoint: Codable, Equatable, Sendable {
    public let count: Int
    public let head: String
    public static let empty = AuditCheckpoint(count: 0, head: String(repeating: "0", count: 64))
    public init(count: Int, head: String) { self.count = count; self.head = head }
}

/// Implement with rollback-resistant trusted storage. Never derive this value
/// from the journal being verified. Losing it requires recovery, not a new log.
@MainActor public protocol AuditCheckpointStore: AnyObject {
    func load() throws -> AuditCheckpoint
    func save(_ checkpoint: AuditCheckpoint) throws
    /// Persist the exact append intent in the same protected storage domain.
    /// Each save is atomic and durable; nil clears only a committed intent.
    func loadPending() throws -> AuditPending?
    func savePending(_ pending: AuditPending?) throws
}

/// Write-ahead evidence contains audit metadata only, never command contents.
/// Recovery can complete these exact bytes; it cannot bless an unexplained tail.
public struct AuditPending: Codable, Equatable, Sendable {
    public let base: AuditCheckpoint
    public let next: AuditCheckpoint
    public let recordBytes: Data
}

/// append must persist before returning and never overwrite prior bytes.
/// The implementation owns an exclusive writer lease for its entire lifetime.
@MainActor public protocol AuditJournal: AnyObject {
    func read() throws -> Data
    func append(_ bytes: Data) throws
}

/// Application creates the containing private directory before first use.
/// Reopen requires the independent checkpoint; missing/truncated files fail validation.
@MainActor public final class FileAuditJournal: AuditJournal {
    private let handle: FileHandle
    private let path: String
    public init(url: URL) throws {
        path = url.path
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PolicyError.auditUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PolicyError.locked }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try verifyFileIdentity()
        // Persist a newly created directory entry before any execution can be released.
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw PolicyError.auditUnavailable }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw PolicyError.auditUnavailable }
    }
    private func verifyFileIdentity() throws {
        var opened = stat(), named = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, lstat(path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_nlink == 1, (opened.st_mode & S_IFMT) == S_IFREG,
              (named.st_mode & S_IFMT) == S_IFREG else { throw PolicyError.tampered }
    }
    public func read() throws -> Data {
        try verifyFileIdentity()
        try handle.seek(toOffset: 0)
        return try handle.readToEnd() ?? Data()
    }
    public func append(_ bytes: Data) throws {
        try verifyFileIdentity()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }
}

public enum AuditEvent: String, Codable, Sendable {
    case suggested, edited, authenticationRequired, approved, denied, queued, duplicate
    case dismissed, expired, dispatched, running, succeeded, failed, cancelled, grantIssued, grantRevoked, sessionRevoked, recovered
}

/// All caller-controlled strings are hashed before reaching this record. No payload,
/// recipient, URI, instruction, transcript, raw identifiers or error descriptions.
public struct AuditRecord: Codable, Equatable, Sendable {
    public let sequence: Int
    public let previousHash: String
    public let timestamp: Int64
    public let event: AuditEvent
    public let subjectHash: String
    public let payloadHash: String
    public let actorHash: String
    public let policyVersion: String
    public let scopeHash: String?
    public let recordHash: String

    fileprivate struct Body: Codable {
        let sequence: Int; let previousHash: String; let timestamp: Int64
        let event: AuditEvent; let subjectHash: String; let payloadHash: String
        let actorHash: String; let policyVersion: String; let scopeHash: String?
    }
    fileprivate var body: Body {
        Body(sequence: sequence, previousHash: previousHash, timestamp: timestamp, event: event,
             subjectHash: subjectHash, payloadHash: payloadHash, actorHash: actorHash, policyVersion: policyVersion, scopeHash: scopeHash)
    }
}

public struct AuditRetention: Sendable {
    /// Age before records are due for encrypted archival. Live journal and replay
    /// tombstones are never erased by retention. Archival transport is later work.
    public let archiveAfterMilliseconds: Int64
    public init(archiveAfterMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1000) throws {
        guard archiveAfterMilliseconds > 0 else { throw PolicyError.invalid }
        self.archiveAfterMilliseconds = archiveAfterMilliseconds
    }
}

@MainActor public final class AuditLog {
    private let journal: any AuditJournal
    private let checkpoints: any AuditCheckpointStore
    public let retention: AuditRetention
    public private(set) var records: [AuditRecord]
    private var checkpoint: AuditCheckpoint
    private var poisoned = false
    // One gate owns each log; sharing a journal across gates would split replay state.
    private var claimed = false

    public init(journal: any AuditJournal, checkpoints: any AuditCheckpointStore,
                retention: AuditRetention) throws {
        self.journal = journal; self.checkpoints = checkpoints; self.retention = retention
        checkpoint = try checkpoints.load()
        guard try checkpoints.loadPending() == nil else { throw PolicyError.auditUnavailable }
        records = try Self.verify(journal.read(), against: checkpoint)
    }
    func claim() throws {
        guard !claimed else { throw PolicyError.locked }
        claimed = true
    }
    public static func verify(_ bytes: Data, against checkpoint: AuditCheckpoint) throws -> [AuditRecord] {
        guard bytes.isEmpty || bytes.last == 10 else { throw PolicyError.tampered }
        let lines = bytes.split(separator: 10, omittingEmptySubsequences: false).dropLast(bytes.isEmpty ? 0 : 1)
        var result: [AuditRecord] = []
        var head = AuditCheckpoint.empty.head
        for line in lines where !bytes.isEmpty {
            let record = try JSONDecoder().decode(AuditRecord.self, from: Data(line))
            guard try canonical(record) == Data(line), record.sequence == result.count, record.previousHash == head,
                  record.recordHash == PayloadDigest.sha256(try canonical(record.body)),
                  record.timestamp >= 0, record.timestamp <= 9_007_199_254_740_991,
                  (record.event == .recovered || record.timestamp >= (result.last?.timestamp ?? 0)) else { throw PolicyError.tampered }
            head = record.recordHash; result.append(record)
        }
        guard result.count == checkpoint.count, head == checkpoint.head else { throw PolicyError.tampered }
        return result
    }
    func checkIntegrity() throws {
        guard !poisoned else { throw PolicyError.auditUnavailable }
        guard try checkpoints.load() == checkpoint, try checkpoints.loadPending() == nil,
              try Self.verify(journal.read(), against: checkpoint) == records else { throw PolicyError.tampered }
    }
    static func makeRecord(event: AuditEvent, subject: String, payloadHash: String, actor: String,
                           now: Int64, checkpoint: AuditCheckpoint, scopeHash: String? = nil) throws -> AuditRecord {
        guard now >= 0, now <= 9_007_199_254_740_991 else { throw PolicyError.clock }
        let body = AuditRecord.Body(sequence: checkpoint.count, previousHash: checkpoint.head,
                                    timestamp: now, event: event, subjectHash: subject,
                                    payloadHash: payloadHash, actorHash: PayloadDigest.sha256(Data(actor.utf8)),
                                    policyVersion: "policy-v1", scopeHash: scopeHash)
        return AuditRecord(sequence: body.sequence, previousHash: body.previousHash, timestamp: now,
                           event: event, subjectHash: subject, payloadHash: payloadHash,
                           actorHash: body.actorHash, policyVersion: body.policyVersion, scopeHash: scopeHash,
                           recordHash: PayloadDigest.sha256(try canonical(body)))
    }
    func append(event: AuditEvent, subject: String, payloadHash: String, actor: String, now: Int64, scopeHash: String? = nil) throws {
        do {
            try checkIntegrity()
            guard event != .recovered, now >= (records.last?.timestamp ?? 0) else { throw PolicyError.clock }
            let record = try Self.makeRecord(event: event, subject: subject, payloadHash: payloadHash,
                                            actor: actor, now: now, checkpoint: checkpoint, scopeHash: scopeHash)
            let next = AuditCheckpoint(count: records.count + 1, head: record.recordHash)
            var bytes = try canonical(record); bytes.append(10)
            try checkpoints.savePending(AuditPending(base: checkpoint, next: next, recordBytes: bytes))
            try journal.append(bytes)
            try checkpoints.save(next)
            try checkpoints.savePending(nil)
            checkpoint = next; records.append(record)
        } catch {
            // No permit is released after an uncertain write. Explicit authenticated
            // recovery must reconcile the durable intent, journal and checkpoint.
            poisoned = true
            throw error
        }
    }
    public func recordsDueForArchival(at now: Int64) -> [AuditRecord] {
        records.filter { now >= $0.timestamp && now - $0.timestamp >= retention.archiveAfterMilliseconds }
    }
}
