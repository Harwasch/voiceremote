import Foundation
import Core
import VoiceRemoteProtocol
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum TextDeliveryState: String, Codable, Sendable {
    case held, unconfirmed, failed, delivered, offline, retentionReview
    public var label: String {
        switch self {
        case .retentionReview: "Retention choice required — open Settings to keep or delete"
        case .held: "Held — tap Send when the computer returns"
        case .unconfirmed: "Sent — insertion unconfirmed; check the computer before resending"
        case .failed: "Insertion failed — text retained"
        case .delivered: "Delivered"
        case .offline: "Offline recording — saved to history only"
        }
    }
}

/// Capture provenance is separate from HistoryEntry.createdAt (retention/receipt time).
public struct OfflineTextOrigin: Codable, Equatable, Sendable {
    public let bootID: UInt32
    public let startTick: UInt64
    public let estimatedUTC: UInt64
    public let interrupted: Bool
    public init(_ metadata: OfflineMetadata) {
        bootID = UInt32(OfflineWire.integer(metadata.raw, 8, 4))
        startTick = OfflineWire.integer(metadata.raw, 12, 8)
        estimatedUTC = OfflineWire.integer(metadata.raw, 20, 8)
        interrupted = metadata.raw[29] & 2 != 0
    }
    public var label: String {
        let time = estimatedUTC == 0
            ? "Capture time unknown · boot \(bootID) · tick \(startTick) ms"
            : "Approximate capture: " + Date(timeIntervalSince1970: Double(estimatedUTC) / 1000).formatted(date: .abbreviated, time: .shortened)
        return interrupted ? time + " · recording interrupted" : time
    }
}

/// Text-only store with explicit deletion. Apple host supplies a protected, backup-excluded URL.
public actor AppHistoryStore: HistoryStore {
    public nonisolated let accountID: String
    private var lastRetentionCheck: Int64
    private var values: [HistoryEntry]
    private var states: [String: TextDeliveryState] = [:]
    private var retentionChoices: [String: Int64] = [:]
    private var origins: [String: OfflineTextOrigin] = [:]
    private struct Snapshot: Codable, Sendable {
        let entries: [HistoryEntry]
        let states: [String: TextDeliveryState]
        let origins: [String: OfflineTextOrigin]?
        let retentionChoices: [String: Int64]?
    }
    private let url: URL?
    public init(url: URL? = nil, now: Int64, accountID: String = "owner-local") throws {
        try RecordAccount.validate(accountID)
        self.accountID = accountID; self.url = url; lastRetentionCheck = now
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let snapshot: Snapshot?
            let object = try JSONSerialization.jsonObject(with: data)
            if let dictionary = object as? [String: Any], dictionary["version"] != nil || dictionary["accountID"] != nil {
                let envelope = try JSONDecoder().decode(AccountRecordEnvelope<Snapshot>.self, from: data)
                try envelope.validate(account: accountID)
                _ = try envelope.records.entries.map { try RecordAccount.bind($0, to: accountID, legacy: false) }
                snapshot = envelope.records
            } else { snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) }
            if let snapshot {
                values = snapshot.entries; states = snapshot.states; origins = snapshot.origins ?? [:]; retentionChoices = snapshot.retentionChoices ?? [:]
            } else { values = try JSONDecoder().decode([HistoryEntry].self, from: data) }
        } else { values = [] }
        values = try values.map { try RecordAccount.bind($0, to: accountID) }
        values = Self.retained(values, states: states, choices: retentionChoices, now: now)
        let retainedIDs = Set(values.map(\.segmentID))
        states = states.filter { retainedIDs.contains($0.key) }
        origins = origins.filter { retainedIDs.contains($0.key) }
        retentionChoices = retentionChoices.filter { retainedIDs.contains($0.key) }
        if let url { try Self.persist(values, states: states, origins: origins, choices: retentionChoices, url: url, accountID: accountID) }
    }
    private static func retained(_ items: [HistoryEntry], states: [String: TextDeliveryState], choices: [String: Int64], now: Int64) -> [HistoryEntry] {
        items.filter {
            if let state = states[$0.segmentID], [.held, .failed, .unconfirmed].contains(state) { return true }
            let start = choices[$0.segmentID] ?? $0.createdAt
            return start >= 0 && start <= now && now - start < 604_800_000
        }
    }
    private static func persist(_ items: [HistoryEntry], states: [String: TextDeliveryState], origins: [String: OfflineTextOrigin], choices: [String: Int64], url: URL, accountID: String) throws {
        let pending = url.appendingPathExtension("pending")
        try? FileManager.default.removeItem(at: pending)
        let descriptor = open(pending.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: pending) }
        try handle.write(contentsOf: JSONEncoder().encode(AccountRecordEnvelope(accountID: accountID, records: Snapshot(entries: items, states: states.filter { key, _ in items.contains { $0.segmentID == key } }, origins: origins.filter { key, _ in items.contains { $0.segmentID == key } }, retentionChoices: choices)))); try handle.synchronize()
        guard rename(pending.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func save(_ items: [HistoryEntry], states nextStates: [String: TextDeliveryState]? = nil, origins nextOrigins: [String: OfflineTextOrigin]? = nil) throws {
        let items = try items.map { try RecordAccount.bind($0, to: accountID) }
        let next = (nextStates ?? states).filter { key, _ in items.contains { $0.segmentID == key } }
        let provenance = (nextOrigins ?? origins).filter { key, _ in items.contains { $0.segmentID == key } }
        let choices = retentionChoices.filter { key, _ in items.contains { $0.segmentID == key } }
        if let url { try Self.persist(items, states: next, origins: provenance, choices: choices, url: url, accountID: accountID) }
        retentionChoices = choices
        values = items; states = next; origins = provenance
    }
    /// Undelivered text survives expiry until shown and explicitly kept or deleted.
    /// A keep choice starts another seven-day review interval without changing capture time.
    public func retentionWarnings(now: Int64) throws -> [HistoryEntry] {
        try purge(now: now)
        return values.filter { entry in
            guard let state = states[entry.segmentID], [.held, .failed, .unconfirmed].contains(state) else { return false }
            let start = retentionChoices[entry.segmentID] ?? entry.createdAt
            return start < 0 || start > now || now - start >= 604_800_000
        }
    }
    public func resolveRetention(id: String, keep: Bool, now: Int64) throws {
        guard try retentionWarnings(now: now).contains(where: { $0.segmentID == id }) else { throw CoreError.unknownSegment }
        if !keep { try delete(id: id, now: now); return }
        let previous = retentionChoices
        retentionChoices[id] = now
        do { try save(values) } catch { retentionChoices = previous; throw error }
    }
    public func deliveryStates() -> [String: TextDeliveryState] {
        var displayed = states
        for entry in values {
            guard let state = states[entry.segmentID], [.held, .failed, .unconfirmed].contains(state) else { continue }
            let start = retentionChoices[entry.segmentID] ?? entry.createdAt
            if start < 0 || start > lastRetentionCheck || lastRetentionCheck - start >= 604_800_000 { displayed[entry.segmentID] = .retentionReview }
        }
        return displayed
    }
    public func offlineOrigins() -> [String: OfflineTextOrigin] { origins }
    public func saveText(_ entry: HistoryEntry, state: TextDeliveryState, now: Int64, origin: OfflineTextOrigin? = nil) throws {
        var next = states; next[entry.segmentID] = state
        var provenance = origins
        if let origin { provenance[entry.segmentID] = origin }
        try save(Self.retained(values.filter { $0.segmentID != entry.segmentID } + [entry], states: next, choices: retentionChoices, now: now), states: next, origins: provenance)
    }
    public func saveTexts(_ entries: [HistoryEntry], now: Int64) throws {
        var next = states
        for entry in entries { next[entry.segmentID] = .held }
        let ids = Set(entries.map(\.segmentID))
        try save(Self.retained(values.filter { !ids.contains($0.segmentID) } + entries, states: next, choices: retentionChoices, now: now), states: next)
    }
    /// Accept only statuses received from the authenticated target session, and
    /// correlate desktop command_id to the original dictation segment ID.
    public func insertionStatus(_ status: TaskStatus, from deviceID: String, accountID: String) throws {
        guard accountID == self.accountID, status.account_id == accountID, status.execution_state == .failed,
              values.contains(where: { $0.segmentID == status.command_id && $0.targetID == deviceID }),
              let state = states[status.command_id], [.unconfirmed, .failed].contains(state) else { return }
        switch status.outcome {
        case .unavailable: try setDelivery(.failed, id: status.command_id)
        case .error: try setDelivery(.unconfirmed, id: status.command_id)
        default: break
        }
    }
    public func dictationOutcome(_ status: DictationOutcome, from deviceID: String, accountID: String) throws {
        guard accountID == self.accountID, status.account_id == accountID, status.target_device_id == deviceID,
              values.contains(where: { $0.segmentID == status.segment_id && $0.targetID == deviceID }),
              let state = states[status.segment_id], [.unconfirmed, .failed].contains(state) else { return }
        switch status.outcome {
        case .inserted: try setDelivery(.delivered, id: status.segment_id)
        case .unavailable: try setDelivery(.failed, id: status.segment_id)
        case .unconfirmed: try setDelivery(.unconfirmed, id: status.segment_id)
        }
    }
    public func finishDelivery(id: String, phone: Bool) throws {
        // An asynchronous desktop failure may arrive before insert() returns.
        guard states[id] == .unconfirmed else { return }
        try setDelivery(.delivered, id: id)
    }
    public func setDelivery(_ state: TextDeliveryState, id: String) throws {
        guard values.contains(where: { $0.segmentID == id }) else { throw CoreError.unknownSegment }
        var next = states; next[id] = state
        try save(values, states: next)
    }
    public func append(_ entry: HistoryEntry, now: Int64) throws { try save(Self.retained(values + [entry], states: states, choices: retentionChoices, now: now)) }
    public func entries(now: Int64) throws -> [HistoryEntry] { try purge(now: now); return values }
    public func purge(now: Int64) throws { try save(Self.retained(values, states: states, choices: retentionChoices, now: now)); lastRetentionCheck = now }
    public func delete(id: String, now: Int64) throws { try save(Self.retained(values.filter { $0.segmentID != id }, states: states, choices: retentionChoices, now: now)) }
}
