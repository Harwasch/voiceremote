import Foundation
import Core
import VoiceRemoteProtocol

/// App adapter reports only literal delivery outcomes, never command authority.
public enum DictationDeliveryError: Error, Equatable, Sendable { case unreachable, failed, unconfirmed, retentionChoiceRequired }
public protocol DictationAvailability: DictationTarget {
    func isReachable(_ deviceID: String) async -> Bool
    func reconcile(segmentID: String, deviceID: String) async throws -> DictationOutcome
    func deliveryEpoch(_ deviceID: String) async -> UUID?
    func insert(_ text: DictationText, expectedEpoch: UUID?) async throws
}
public extension DictationAvailability {
    func reconcile(segmentID: String, deviceID: String) async throws -> DictationOutcome { throw DictationDeliveryError.unconfirmed }
    func deliveryEpoch(_ deviceID: String) async -> UUID? { nil }
    func insert(_ text: DictationText, expectedEpoch: UUID?) async throws { try await insert(text) }
}

/// Pins the target before capture, journals text before I/O, and never replays on reconnect.
public actor HeldDictationPipeline {
    private let history: AppHistoryStore
    private let target: any DictationTarget
    private let registry: DeviceRegistry
    private struct Prepared {
        let device: DeviceInfo
        let allowDelivery: Bool
        let linkEpoch: UUID?
    }
    private var prepared: [String: Prepared] = [:]
    private var preparing: [String: UUID] = [:]
    private var sending = Set<String>()
    private let accountID: String
    private let phoneID: String
    public init(history: AppHistoryStore, target: any DictationTarget, registry: DeviceRegistry, accountID: String, phoneID: String) {
        self.history = history; self.target = target; self.registry = registry; self.phoneID = phoneID
        self.accountID = accountID
    }
    public func prepare(segmentID: String, state: AppState, picker: TargetPicker, now: Int64) async throws -> DeviceInfo {
        guard state.mode == .dictation else { throw CoreError.wrongMode }
        guard prepared[segmentID] == nil, preparing[segmentID] == nil else { throw CoreError.unknownSegment }
        let token = UUID(); preparing[segmentID] = token
        defer { preparing.removeValue(forKey: segmentID) }
        var selected = picker; selected.selection = state.target
        let device = try selected.resolve(devices: await registry.all())
        guard device.account_id == accountID else { throw CoreError.wrongAccount }
        var allowDelivery = true
        do { try await target.showTarget(device) }
        catch {
            allowDelivery = false
            // Destination is still pinned and displayed in the phone UI. Missing
            // desktop presentation must not discard locally captured dictation.
            guard device.device_id != phoneID else { throw error }
        }
        var linkEpoch: UUID?
        if let availability = target as? any DictationAvailability {
            let reachable = await availability.isReachable(device.device_id)
            allowDelivery = allowDelivery && reachable
            linkEpoch = await availability.deliveryEpoch(device.device_id)
        }
        guard preparing[segmentID] == token else { throw CancellationError() }
        prepared[segmentID] = Prepared(device: device, allowDelivery: allowDelivery, linkEpoch: linkEpoch)
        return device
    }
    public func cancel(segmentID: String) { preparing.removeValue(forKey: segmentID); prepared.removeValue(forKey: segmentID) }
    public func commit(segmentID: String, revision: Int64, text: String, now: Int64) async throws {
        guard let pinned = prepared.removeValue(forKey: segmentID) else { throw CoreError.unknownSegment }
        let device = pinned.device
        let clean = DictationPipeline.sanitize(text)
        guard !clean.isEmpty else { return }
        let entries = Self.parts(clean).enumerated().map { index, part in
            HistoryEntry(segmentID: index == 0 ? segmentID : HistoryTextIdentity.copyID(segmentID + ":" + String(index)).uuidString,
                         targetID: device.device_id, text: part, createdAt: now, accountID: accountID)
        }
        // Journal every scalar before wire validation or delivery can fail.
        try await history.saveTexts(entries, now: now)
        for entry in entries { _ = try ProtocolCodec.encode(message(entry, revision: revision)) }
        if device.device_id != phoneID {
            guard (try? await registry.textReceiver(device.device_id)) != nil else { return }
        }
        guard pinned.allowDelivery else { return }
        if let availability = target as? any DictationAvailability {
            guard await availability.isReachable(device.device_id) else { return }
            if let original = pinned.linkEpoch {
                guard await availability.deliveryEpoch(device.device_id) == original else { return }
            }
        }
        for entry in entries { try await deliver(entry, revision: revision, expectedEpoch: pinned.linkEpoch) }
    }
    private static func parts(_ text: String) -> [String] {
        var result: [String] = [], current = "", count = 0
        // Byte bound also fits the keyboard queue. Prefer grapheme boundaries; large clusters still
        // split only at Unicode scalar boundaries, preserving every byte on join.
        for character in text {
            let piece = String(character), size = piece.utf8.count
            if size <= 16384 {
                if count + size > 16384 { result.append(current); current = ""; count = 0 }
                current += piece; count += size
            } else {
                for scalar in piece.unicodeScalars {
                    let scalarBytes = String(scalar).utf8.count
                    if count + scalarBytes > 16384 { result.append(current); current = ""; count = 0 }
                    current.unicodeScalars.append(scalar); count += scalarBytes
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    /// This is invoked exclusively by the history Send tap. Refresh/reconnect never calls it.
    public func sendHeld(id: String, now: Int64) async throws {
        guard !sending.contains(id) else { throw CoreError.unknownSegment }
        sending.insert(id); defer { sending.remove(id) }
        guard try await !history.retentionWarnings(now: now).contains(where: { $0.segmentID == id }) else { throw DictationDeliveryError.retentionChoiceRequired }
        guard let entry = try await history.entries(now: now).first(where: { $0.segmentID == id }),
              entry.accountID == accountID,
              let state = await history.deliveryStates()[id], [.held, .failed, .unconfirmed].contains(state) else { throw CoreError.unknownSegment }
        if state == .unconfirmed {
            guard let availability = target as? any DictationAvailability else { throw DictationDeliveryError.unconfirmed }
            let outcome = try await availability.reconcile(segmentID: id, deviceID: entry.targetID)
            guard outcome.account_id == accountID, outcome.target_device_id == entry.targetID,
                  outcome.segment_id == entry.segmentID else { throw DictationDeliveryError.unconfirmed }
            try await history.dictationOutcome(outcome, from: entry.targetID, accountID: accountID)
            if outcome.outcome == .inserted { return }
            guard outcome.outcome == .unavailable else { throw DictationDeliveryError.unconfirmed }
        }
        if entry.targetID != phoneID { _ = try await registry.textReceiver(entry.targetID) }
        let device = entry.targetID == phoneID ? TargetPicker(accountID: accountID, phoneID: phoneID).phone : try await registry.textReceiver(entry.targetID)
        try await target.showTarget(device)
        let epoch = await (target as? any DictationAvailability)?.deliveryEpoch(device.device_id)
        try await deliver(entry, revision: 0, expectedEpoch: epoch)
    }
    private func message(_ entry: HistoryEntry, revision: Int64) -> DictationText {
        DictationText(account_id: accountID, segment_id: entry.segmentID, revision: revision, state: .committed,
                      target_device_id: entry.targetID, text: entry.text)
    }
    private func deliver(_ entry: HistoryEntry, revision: Int64, expectedEpoch: UUID? = nil) async throws {
        try Task.checkCancellation()
        // Crash during/after a write is ambiguous. Persist that fact before sending.
        try await history.setDelivery(.unconfirmed, id: entry.segmentID)
        do {
            if entry.targetID != phoneID { _ = try await registry.textReceiver(entry.targetID) }
            try Task.checkCancellation()
            if let availability = target as? any DictationAvailability {
                try await availability.insert(message(entry, revision: revision), expectedEpoch: expectedEpoch)
            } else { try await target.insert(message(entry, revision: revision)) }
            try await history.finishDelivery(id: entry.segmentID, phone: entry.targetID == phoneID)
        } catch DictationDeliveryError.unreachable { try await history.setDelivery(.held, id: entry.segmentID) }
        catch DictationDeliveryError.failed { try await history.setDelivery(.failed, id: entry.segmentID) }
        catch { /* A transport failure may follow a successful write. Keep unconfirmed. */ }
    }
}
