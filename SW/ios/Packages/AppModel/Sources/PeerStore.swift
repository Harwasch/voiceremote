import Foundation
import Core
import VoiceRemoteProtocol
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Metadata only. Public/private identity keys remain in the host Keychain adapter.
public struct StoredPeer: Codable, Equatable, Sendable {
    public let device: DeviceInfo
    public let roomID: String
    public var revoked = false
    public var notificationPending = false
}
@MainActor public final class PeerStore {
    public private(set) var records: [StoredPeer]
    public var active: [StoredPeer] { records.filter { !$0.revoked } }
    private let url: URL
    private let accountID: String
    public init(url: URL, accountID: String) throws {
        self.url = url; self.accountID = accountID
        records = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([StoredPeer].self, from: Data(contentsOf: url)) : []
        guard Set(records.map { $0.device.device_id }).count == records.count else { throw CocoaError(.fileReadCorruptFile) }
        for record in records {
            _ = try ProtocolCodec.encode(record.device)
            guard record.device.account_id == accountID, !record.roomID.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    /// Restore only enrollments whose Keychain key still exists. Tombstones are
    /// never replayed into Core, even if the previous process died during revoke.
    @discardableResult public func restore(registry: DeviceRegistry, keyAvailable: (String) throws -> Bool) async throws -> [String] {
        var missing: [String] = []
        for record in active {
            let id = record.device.device_id
            guard try keyAvailable(id) else {
                try markRevoked(deviceID: id, notificationPending: true); missing.append(id); continue
            }
            try await registry.register(record.device)
        }
        return missing
    }
    public func enroll(_ device: DeviceInfo, roomID: String) throws {
        _ = try ProtocolCodec.encode(device)
        guard device.account_id == accountID, !roomID.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        var next = records.filter { $0.device.device_id != device.device_id }
        next.append(StoredPeer(device: device, roomID: roomID))
        try write(next)
    }
    public func markRevoked(deviceID: String, notificationPending: Bool) throws {
        var next = records
        if let index = next.firstIndex(where: { $0.device.device_id == deviceID }) {
            next[index].revoked = true; next[index].notificationPending = notificationPending
        }
        try write(next)
    }
    private func write(_ next: [StoredPeer]) throws {
        try PrivateJSONFile.write(JSONEncoder().encode(next), to: url); records = next
    }
}

/// Synchronous persistence makes consent withdrawal durable before returning.
public struct SettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AppSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
    }
    public func save(_ settings: AppSettings) throws { try PrivateJSONFile.write(JSONEncoder().encode(settings), to: url) }
}
private enum PrivateJSONFile {
    static func write(_ data: Data, to url: URL) throws {
        let pending = url.appendingPathExtension("pending")
        try? FileManager.default.removeItem(at: pending)
        let fd = open(pending.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: pending) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: pending.path)
        #endif
        try file.write(contentsOf: data); try file.synchronize()
        guard rename(pending.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
