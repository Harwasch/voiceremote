import Foundation
import Crypto
import Stt

// Draft 1.1 little-endian offline contract. No live Audio framing is reused here.
public enum OfflineWire {
    public static func integer(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt64 {
        data.dropFirst(offset).prefix(bytes).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    public static func le(_ value: UInt64, _ bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
    public static func fragments(_ payload: Data, transaction: UInt16, budget: Int) throws -> [Data] {
        guard budget > 6, (1...512).contains(payload.count) else { throw RemoteContractError.malformed }
        return stride(from: 0, to: payload.count, by: budget - 6).map { offset in
            le(UInt64(transaction), 2) + le(UInt64(payload.count), 2) + le(UInt64(offset), 2) + payload.subdata(in: offset..<min(payload.count, offset + budget - 6))
        }
    }
}

public struct OfflineAssembly: Sendable {
    private var transaction: UInt16?
    private var length = 0
    private var bytes = Data()
    public init() {}
    public mutating func reset() { transaction = nil; bytes = Data(); length = 0 }
    public mutating func accept(_ fragment: Data, expected: UInt16? = nil, maximum: Int = 512) throws -> (UInt16, Data)? {
        guard fragment.count > 6 else { throw RemoteContractError.malformed }
        let id = UInt16(OfflineWire.integer(fragment, 0, 2)), size = Int(OfflineWire.integer(fragment, 2, 2))
        let offset = Int(OfflineWire.integer(fragment, 4, 2)), chunk = Data(fragment.dropFirst(6))
        if let expected, id != expected { return nil } // late cancelled reply
        guard (2...maximum).contains(size), offset + chunk.count <= size else { throw RemoteContractError.malformed }
        if offset == 0 { transaction = id; length = size; bytes = Data() }
        guard transaction == id, length == size, offset == bytes.count else { reset(); throw RemoteContractError.loss }
        bytes += chunk
        if bytes.count == length { let result = bytes; reset(); return (id, result) }
        return nil
    }
}

public struct OfflineMetadata: Codable, Equatable, Sendable {
    public let raw: Data
    public var id: UInt64 { OfflineWire.integer(raw, 0, 8) }
    public var size: Int { Int(OfflineWire.integer(raw, 30, 4)) }
    public var frames: Int { Int(OfflineWire.integer(raw, 34, 4)) }
    public var crc: UInt32 { UInt32(OfflineWire.integer(raw, 38, 4)) }
    public init(_ raw: Data) throws {
        guard raw.count == 42, OfflineWire.integer(raw, 0, 8) > 0, raw[28] <= 1,
              raw[29] & 0xfc == 0, raw[29] & 1 == 1,
              OfflineWire.integer(raw, 30, 4) > 0, OfflineWire.integer(raw, 34, 4) > 0,
              OfflineWire.integer(raw, 20, 8) <= 253_402_300_799_999 else { throw RemoteContractError.malformed }
        self.raw = raw
    }
    private enum CodingKeys: String, CodingKey { case raw }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(Data.self, forKey: .raw))
    }
    public func packets(_ audio: Data, maximum: Int) throws -> [Data] {
        guard audio.count == size, OfflineWire.crc32(audio) == crc else { throw RemoteContractError.loss }
        var packets: [Data] = []; var offset = 0
        while offset < audio.count {
            guard audio.count - offset >= 2 else { throw RemoteContractError.malformed }
            let count = Int(OfflineWire.integer(audio, offset, 2)); offset += 2
            guard (1...maximum).contains(count), count <= audio.count - offset else { throw RemoteContractError.malformed }
            packets.append(audio.subdata(in: offset..<offset+count)); offset += count
        }
        guard packets.count == frames else { throw RemoteContractError.loss }
        return packets
    }
}

public struct OfflineProgress: Sendable {
    public let status: UInt8
    public let waiting: UInt32
    public let bootID: UInt32
    public let tick: UInt64
    public init(_ data: Data, minor: UInt8) throws {
        guard data.count == 46, data[1] == 0, (minor > 1 || data[0] & 0xe0 == 0), data[0] & 3 != 3,
              OfflineWire.integer(data, 6, 8) <= OfflineWire.integer(data, 14, 8) else { throw RemoteContractError.malformed }
        status = data[0] & 0x1f; waiting = UInt32(OfflineWire.integer(data, 2, 4))
        bootID = UInt32(OfflineWire.integer(data, 34, 4)); tick = OfflineWire.integer(data, 38, 8)
    }
}

public struct OfflineSyncIssue: Identifiable, Sendable {
    public let id: String
    public let recordingID: UInt64
    public let reason: String
}
/// A deliberate live-capture preemption differs from an ambiguous process crash.
public final class OfflineSyncInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var yielded = false
    public init() {}
    public func yieldToLiveCapture() { lock.withLock { yielded = true } }
    public var isLiveYield: Bool { lock.withLock { yielded } }
}

/// Metadata is journaled separately from append-only, protected per-record audio.
/// Only explicit discard or successful transcription can remove the source.
public actor RemoteOfflineSync {
    public typealias Request = @Sendable (Data) async throws -> Data
    public typealias Transcribe = @Sendable ([Data]) async throws -> String
    public typealias SaveText = @Sendable (String, String) async throws -> Void
    private struct Record: Codable {
        let remote: String
        let metadata: OfflineMetadata
        var audio: Data? // one-time migration of the earlier base64 journal
        var text: String?
        var textCreatedAt: Int64?
        var sttAttempted: Bool?
        var issue: String?
        var discarded = false
        var historySaved = false
        var deleted = false
    }
    private let now: @Sendable () -> Int64
    private let url: URL
    private let audioDirectory: URL
    private var records: [String: Record]
    private var running = false
    public private(set) var audioBytesWritten: UInt64 = 0
    public init(url: URL, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        self.now = now
        self.url = url; audioDirectory = url.appendingPathExtension("audio")
        try? FileManager.default.removeItem(at: url.appendingPathExtension("pending"))
        records = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: url)) : [:]
        try Self.prepareDirectory(audioDirectory)
        var migrated = false
        for key in Array(records.keys) {
            guard var record = records[key] else { continue }
            if let old = record.audio {
                if !old.isEmpty, !record.deleted, record.text == nil, !record.discarded {
                    try Self.createAudio(old, at: audioDirectory.appendingPathComponent(key))
                }
                record.audio = nil; records[key] = record; migrated = true
            }
            if record.historySaved || record.deleted {
                record.text = nil; record.textCreatedAt = nil; records[key] = record; migrated = true
            } else if record.text != nil {
                // Legacy pending text gets one bounded migration interval.
                record.textCreatedAt = record.textCreatedAt ?? now()
                if let created = record.textCreatedAt, created > now() || created < 0 || now() - created >= 604_800_000 {
                    record.text = nil; record.textCreatedAt = nil; record.sttAttempted = true
                    record.issue = "Pending transcript expired. Source remains on the remote; Retry or Discard explicitly."
                }
                records[key] = record; migrated = true
            }
            if record.text != nil || record.historySaved || record.discarded || record.deleted {
                let completedAudio = audioDirectory.appendingPathComponent(key)
                if FileManager.default.fileExists(atPath: completedAudio.path) { try FileManager.default.removeItem(at: completedAudio) }
            }
        }
        // Audio without a resumable record can only be an abandoned local copy;
        // the remote remains authoritative until history has been saved.
        let pendingAudio = Set(records.filter { !$0.value.deleted && !$0.value.discarded && !$0.value.historySaved && $0.value.text == nil }.keys)
        for file in try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
            where !pendingAudio.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
        if migrated { try PrivateJSONFile.write(JSONEncoder().encode(records), to: url) }
    }
    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var protected = url; try protected.setResourceValues(resource)
        #endif
    }
    private static func createAudio(_ bytes: Data, at url: URL) throws {
        // Atomic private creation, never an ordinary world-readable Data.write.
        if FileManager.default.fileExists(atPath: url.path) { return }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.write(contentsOf: bytes); try file.synchronize()
    }
    private func audioURL(_ key: String) -> URL { audioDirectory.appendingPathComponent(key) }
    private func audioSize(_ key: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: audioURL(key).path)[.size] as? NSNumber)?.intValue ?? 0
    }
    private func append(_ bytes: Data, key: String, expectedOffset: Int) throws {
        let url = audioURL(key)
        try Self.createAudio(Data(), at: url)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(expectedOffset) else { throw RemoteContractError.loss }
        try file.write(contentsOf: bytes); try file.synchronize()
        audioBytesWritten += UInt64(bytes.count)
    }
    public static func historyID(remote: String, recording: UInt64) -> String {
        let hash = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
        return "offline-" + hash + "-" + String(recording)
    }
    private func save(_ record: Record, key: String) throws {
        var next = records; next[key] = record
        try PrivateJSONFile.write(JSONEncoder().encode(next), to: url); records = next
    }
    private func reply(_ request: Data, using send: Request) async throws -> Data {
        try Task.checkCancellation()
        let data = try await send(request)
        guard data.count >= 2, data[0] == request[0], data[1] <= 5 else { throw RemoteContractError.malformed }
        if data[1] != 0 {
            guard data.count == 2 else { throw RemoteContractError.malformed }
            if request[0] == 2, data[1] == 1 { return data }
            throw RemoteContractError.notReady
        }
        return data
    }
    /// Expire pending text even while no remote is connected. Never interrupt an
    /// in-flight transcription; source audio still follows its STT disposition.
    public func maintain() throws {
        guard !running else { return }
        try expirePendingText()
    }
    private func expirePendingText() throws {
        for (key, value) in records where value.text != nil && !value.historySaved {
            if let created = value.textCreatedAt, created < 0 || created > now() || now() - created >= 604_800_000 {
                var expired = value; expired.text = nil; expired.textCreatedAt = nil; expired.sttAttempted = true
                expired.issue = "Pending transcript expired. Source remains on the remote; Retry or Discard explicitly."
                try save(expired, key: key)
            }
        }
    }
    public func synchronize(remote: String, info: RemoteInfo, enrolled: Bool, progress: OfflineProgress,
                            utcMilliseconds: UInt64, interruption: OfflineSyncInterruption? = nil, allowAudioFetch: Bool = true,
                            request: Request, transcribe: Transcribe, saveText: SaveText) async throws {
        guard enrolled, info.supportsOfflineSync, !running, progress.status & 3 == 0 else { throw RemoteContractError.notReady }
        running = true; defer { running = false }
        try expirePendingText()
        let clock = Data([1]) + OfflineWire.le(UInt64(progress.bootID), 4) + OfflineWire.le(progress.tick, 8) + OfflineWire.le(utcMilliseconds, 8)
        guard try await reply(clock, using: request).count == 2 else { throw RemoteContractError.malformed }
        var failed = false, visited = Set<String>()
        // A failed confirmation/history save must not starve a later recording.
        for (key, record) in records.sorted(by: { $0.key < $1.key }) where record.remote == remote && !record.deleted && (record.text != nil || record.historySaved || record.discarded) {
            visited.insert(key)
            do { try await finish(record, key: key, request: request, saveText: saveText) }
            catch { try Task.checkCancellation(); failed = true }
        }
        var cursor: UInt64 = 0
        while true {
            let listed = try await reply(Data([2]) + OfflineWire.le(cursor, 8), using: request)
            if listed[1] == 1 { break }
            guard listed.count == 44 else { throw RemoteContractError.malformed }
            let metadata = try OfflineMetadata(Data(listed.dropFirst(2)))
            guard metadata.id > cursor else { throw RemoteContractError.malformed }; cursor = metadata.id
            let key = Self.historyID(remote: remote, recording: metadata.id)
            if visited.contains(key) { continue }
            var record = records[key] ?? Record(remote: remote, metadata: metadata)
            if record.deleted { continue }
            do {
                if record.metadata != metadata {
                    guard record.text == nil, !record.discarded, record.sttAttempted != true else { throw RemoteContractError.loss }
                    try? FileManager.default.removeItem(at: audioURL(key))
                    record = Record(remote: remote, metadata: metadata)
                }
                if let prior = record.issue, record.sttAttempted == true { _ = prior; failed = true; continue }
                guard metadata.size <= 64 * 1024 * 1024 else {
                    record.issue = "Recording exceeds the phone transfer limit. Discard explicitly or retain on remote."
                    try save(record, key: key); failed = true; continue
                }
                try save(record, key: key) // metadata once, never once per chunk
                guard allowAudioFetch else {
                    record.issue = "Remote is OFF. Fetch waits; explicit discard remains available."
                    try save(record, key: key); failed = true; continue
                }
                var offset = audioSize(key)
                guard offset <= metadata.size else { throw RemoteContractError.loss }
                while offset < metadata.size {
                    let count = min(496, metadata.size - offset)
                    let fetch = Data([3]) + OfflineWire.le(metadata.id, 8) + OfflineWire.le(UInt64(offset), 4) + OfflineWire.le(UInt64(count), 2)
                    let data = try await reply(fetch, using: request)
                    guard data.count >= 16, OfflineWire.integer(data, 2, 8) == metadata.id,
                          OfflineWire.integer(data, 10, 4) == UInt64(offset),
                          OfflineWire.integer(data, 14, 2) == UInt64(count), data.count == 16 + count else { throw RemoteContractError.malformed }
                    try append(Data(data.dropFirst(16)), key: key, expectedOffset: offset); offset += count
                }
                let packets = try metadata.packets(Data(contentsOf: audioURL(key)), maximum: info.maxPacket)
                if metadata.frames < 15 { record.discarded = true }
                else {
                    guard record.sttAttempted != true else { throw RemoteContractError.notReady }
                    record.sttAttempted = true; record.issue = nil; try save(record, key: key)
                    let text = try await transcribe(packets)
                    try Task.checkCancellation()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        record.issue = "No speech recognized. Retry or explicitly discard this recording."
                        try save(record, key: key); failed = true; continue
                    }
                    record.text = text; record.sttAttempted = nil
                }
                record.textCreatedAt = record.text == nil ? nil : now()
                record.issue = nil; try save(record, key: key)
                try FileManager.default.removeItem(at: audioURL(key))
                try await finish(record, key: key, request: request, saveText: saveText)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    if interruption?.isLiveYield == true {
                        record.sttAttempted = nil; record.issue = nil; try save(record, key: key)
                    }
                    throw CancellationError()
                }
                // Reload after finish() may have durably advanced history state.
                var retained = records[key] ?? record
                retained.issue = retained.sttAttempted == true ? "Transcription failed. Retry or explicitly discard." : "Transfer or history failed. Retry or explicitly discard."
                try save(retained, key: key); failed = true
            }
        }
        if failed { throw RemoteContractError.notReady }
    }
    private func finish(_ value: Record, key: String, request: Request, saveText: SaveText) async throws {
        var record = value
        if let text = record.text, !record.historySaved {
            try await saveText(key, text); record.historySaved = true
            record.text = nil; record.textCreatedAt = nil; try save(record, key: key)
        }
        guard record.discarded || record.historySaved else { throw RemoteContractError.notReady }
        if FileManager.default.fileExists(atPath: audioURL(key).path) { try FileManager.default.removeItem(at: audioURL(key)) }
        let confirm = Data([4]) + OfflineWire.le(record.metadata.id, 8) + OfflineWire.le(UInt64(record.metadata.size), 4) + OfflineWire.le(UInt64(record.metadata.crc), 4)
        guard try await reply(confirm, using: request).count == 2 else { throw RemoteContractError.malformed }
        record.deleted = true; record.text = nil; record.issue = nil; try save(record, key: key)
    }
    public func discard(id: String, remote: String) throws {
        guard !running, var record = records[id], record.remote == remote, !record.deleted else { throw RemoteContractError.notReady }
        record.discarded = true; record.issue = nil; record.sttAttempted = nil
        try save(record, key: id) // disposition durable before source deletion or C4
        if FileManager.default.fileExists(atPath: audioURL(id).path) { try FileManager.default.removeItem(at: audioURL(id)) }
    }
    public func issues(remote: String) -> [OfflineSyncIssue] {
        records.compactMap { key, value in
            guard value.remote == remote, !value.deleted, let reason = value.issue else { return nil }
            return OfflineSyncIssue(id: key, recordingID: value.metadata.id, reason: reason)
        }.sorted { $0.recordingID < $1.recordingID }
    }
    public func retryFailedTranscriptions(remote: String) throws {
        guard !running else { throw RemoteContractError.notReady }
        for (key, value) in records where value.remote == remote && !value.deleted {
            var record = value; record.sttAttempted = nil; record.issue = nil; try save(record, key: key)
        }
    }
    public func metadata(for id: String) -> OfflineMetadata? { records[id]?.metadata }
    public func pendingAudioBytes() -> Int { records.keys.reduce(0) { $0 + audioSize($1) } }
}
