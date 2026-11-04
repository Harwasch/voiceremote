import Foundation
#if canImport(Darwin)
import Darwin
import CoreFoundation
#else
import Glibc
#endif

public enum BridgeError: Error { case invalidText, expired, capacity, invalidFile, io }

/// Only committed text belongs here. IDs and creation times must remain stable on retry.
public struct CommittedSegment: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public init(id: UUID, createdAt: Date, text: String) {
        self.id = id; self.createdAt = createdAt; self.text = text
    }
}

@MainActor public protocol TextInserter {
    func insertText(_ text: String) throws
}

public enum BridgePolicy {
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public static let maxFileBytes = 262_144
    public static let maxSegments = 1024
    public static let maxTextBytes = 16_384
    public static let queueFilename = "keyboard-queue-v1.json"
    public static let notificationName = "com.voiceremote.keyboard.queue-changed.v1"

    public static func validate(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= maxTextBytes,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { throw BridgeError.invalidText }
    }
    static func live(_ date: Date, now: Date) -> Bool {
        date <= now && now.timeIntervalSince(date) < retention
    }
}

private struct QueueFile: Codable {
    var version = 1
    var listening = false
    var segments: [CommittedSegment] = []
}
private struct Receipt: Codable { let id: UUID; let createdAt: Date }
private struct Ledger: Codable { var version = 1; var receipts: [Receipt] = [] }

/// The containing app is the only writer. The extension opens this file read-only.
public final class QueueWriter {
    private let directory: URL
    public init(sharedDirectory: URL) { directory = sharedDirectory }

    /// Call periodically in the app, including at launch, even when no text is produced.
    public func maintain(listening: Bool, now: Date = Date()) throws {
        try update(segment: nil, listening: listening, now: now)
    }
    public func enqueue(_ segment: CommittedSegment, listening: Bool, now: Date = Date()) throws {
        try BridgePolicy.validate(segment.text)
        guard BridgePolicy.live(segment.createdAt, now: now) else { throw BridgeError.expired }
        try update(segment: segment, listening: listening, now: now)
    }
    /// Only a receipt persisted after the keyboard's insertion call proves success.
    /// Enqueue and the receipt-before-call dedup ledger never imply delivery.
    public func insertionConfirmed(id: UUID, now: Date = Date()) throws -> Bool {
        let ledger = try read(Ledger.self, from: directory.appendingPathComponent("keyboard-inserted-v1.json")) ?? Ledger()
        guard ledger.version == 1, ledger.receipts.count <= BridgePolicy.maxSegments else { throw BridgeError.invalidFile }
        return ledger.receipts.contains { $0.id == id && BridgePolicy.live($0.createdAt, now: now) }
    }
    private func update(segment: CommittedSegment?, listening: Bool, now: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try withFileLock(directory.appendingPathComponent("writer.lock")) {
            let url = directory.appendingPathComponent(BridgePolicy.queueFilename)
            _ = unlink(url.appendingPathExtension("pending").path)
            var queue = try readQueue(url, now: now)
            queue.listening = listening
            if let segment, !queue.segments.contains(where: { $0.id == segment.id }) {
                guard queue.segments.count < BridgePolicy.maxSegments else { throw BridgeError.capacity }
                queue.segments.append(segment)
            }
            try persist(queue, to: url)
        }
        postQueueChanged()
    }
}

public struct KeyboardStatus: Equatable, Sendable {
    public let listening: Bool
    public let pendingCount: Int
}

/// Receipt-before-insertion gives at-most-once attempts, not exactly-once insertion.
/// Keep the local ledger across controller/process restarts. Never reset it on activation.
public final class QueueReader {
    private let sharedDirectory: URL
    private let queueURL: URL
    private let localDirectory: URL
    public init(sharedDirectory: URL, localDirectory: URL) {
        self.sharedDirectory = sharedDirectory
        queueURL = sharedDirectory.appendingPathComponent(BridgePolicy.queueFilename)
        self.localDirectory = localDirectory
    }
    public func status(now: Date = Date()) throws -> KeyboardStatus {
        let queue = try readQueue(queueURL, now: now)
        return KeyboardStatus(listening: queue.listening, pendingCount: queue.segments.count)
    }

    @MainActor @discardableResult
    public func drain(into inserter: any TextInserter, now: Date = Date()) throws -> Int {
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        return try withFileLock(localDirectory.appendingPathComponent("reader.lock")) {
            let url = localDirectory.appendingPathComponent("receipts-v1.json")
            _ = unlink(url.appendingPathExtension("pending").path)
            var ledger = try read(Ledger.self, from: url) ?? Ledger()
            guard ledger.version == 1, ledger.receipts.count <= BridgePolicy.maxSegments else {
                throw BridgeError.invalidFile
            }
            ledger.receipts.removeAll { !BridgePolicy.live($0.createdAt, now: now) }
            let queue = try readQueue(queueURL, now: now)
            var inserted = 0
            for segment in queue.segments where !ledger.receipts.contains(where: { $0.id == segment.id }) {
                guard ledger.receipts.count < BridgePolicy.maxSegments else { throw BridgeError.capacity }
                ledger.receipts.append(Receipt(id: segment.id, createdAt: segment.createdAt))
                // Sync the receipt and its directory before the nontransactional UIKit call.
                try persist(ledger, to: url)
                try inserter.insertText(segment.text)
                // Crash or a throwing insertion leaves no positive receipt. The
                // earlier local receipt still prevents a second UIKit attempt.
                try withFileLock(sharedDirectory.appendingPathComponent("outcomes.lock")) {
                    let outcomesURL = sharedDirectory.appendingPathComponent("keyboard-inserted-v1.json")
                    var outcomes = try read(Ledger.self, from: outcomesURL) ?? Ledger()
                    guard outcomes.version == 1, outcomes.receipts.count <= BridgePolicy.maxSegments else { throw BridgeError.invalidFile }
                    outcomes.receipts.removeAll { !BridgePolicy.live($0.createdAt, now: now) }
                    guard outcomes.receipts.count < BridgePolicy.maxSegments else { throw BridgeError.capacity }
                    outcomes.receipts.append(Receipt(id: segment.id, createdAt: segment.createdAt))
                    try persist(outcomes, to: outcomesURL)
                }
                inserted += 1
            }
            // Prune old receipts even when there is no pending text.
            try persist(ledger, to: url)
            return inserted
        }
    }
}

private func readQueue(_ url: URL, now: Date) throws -> QueueFile {
    var queue = try read(QueueFile.self, from: url) ?? QueueFile()
    guard queue.version == 1, queue.segments.count <= BridgePolicy.maxSegments,
          Set(queue.segments.map(\.id)).count == queue.segments.count else { throw BridgeError.invalidFile }
    for segment in queue.segments { try BridgePolicy.validate(segment.text) }
    queue.segments.removeAll { !BridgePolicy.live($0.createdAt, now: now) }
    return queue
}

private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: BridgePolicy.maxFileBytes + 1) ?? Data()
    guard data.count <= BridgePolicy.maxFileBytes else { throw BridgeError.capacity }
    return try JSONDecoder().decode(type, from: data)
}

private func persist<T: Encodable>(_ value: T, to url: URL) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= BridgePolicy.maxFileBytes else { throw BridgeError.capacity }
    let temporary = url.appendingPathExtension("pending")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw BridgeError.io }
    defer { _ = close(fd); _ = unlink(temporary.path) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError.io }
            offset += count
        }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw BridgeError.io }
    let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
    guard parent >= 0 else { throw BridgeError.io }
    defer { _ = close(parent) }
    guard fsync(parent) == 0 else { throw BridgeError.io }
}

private func withFileLock<T>(_ url: URL, body: () throws -> T) throws -> T {
    let fd = open(url.path, O_RDWR | O_CREAT, mode_t(0o600))
    guard fd >= 0 else { throw BridgeError.io }
    defer { _ = close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw BridgeError.io }
    defer { _ = flock(fd, LOCK_UN) }
    return try body()
}

private func postQueueChanged() {
    #if canImport(Darwin)
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(rawValue: BridgePolicy.notificationName as CFString), nil, nil, true)
    #endif
}
