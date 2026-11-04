import VoiceRemoteProtocol

public enum CoreError: Error, Equatable {
    case wrongAccount, unavailableTarget, wrongMode, unknownSegment, revokedDevice
    case duplicateDevice, rePairRequiresRevocation, revocationIncomplete
}

/// UI adapters delete the device credential and leave its relay room.
public protocol DeviceRevocationHandler: Sendable {
    func deleteKey(deviceID: String) async throws
    func dropRoom(deviceID: String) async throws
}

public actor DeviceRegistry {
    public let accountID: String
    private var devices: [String: DeviceInfo] = [:]
    private var revoked: Set<String> = []
    private var cleanupComplete: Set<String> = []
    private var cleanupPending: Set<String> = []
    private let revocation: any DeviceRevocationHandler
    public init(accountID: String, revocation: any DeviceRevocationHandler) {
        self.accountID = accountID
        self.revocation = revocation
    }
    /// Call only after authenticated enrollment and both phrase confirmations.
    public func register(_ device: DeviceInfo) throws {
        guard device.account_id == accountID else { throw CoreError.wrongAccount }
        guard !revoked.contains(device.device_id) else { throw CoreError.revokedDevice }
        guard devices[device.device_id] == nil else { throw CoreError.duplicateDevice }
        _ = try ProtocolCodec.encode(device)
        devices[device.device_id] = device
    }
    /// Explicit trusted re-pair step after revoke has succeeded and a NEW pairing
    /// completed both phrase confirmations. Install the new key only after this
    /// succeeds; ordinary register never overwrites an enrolled or revoked ID.
    public func rePair(_ device: DeviceInfo) throws {
        guard device.account_id == accountID else { throw CoreError.wrongAccount }
        guard revoked.contains(device.device_id) else { throw CoreError.rePairRequiresRevocation }
        guard cleanupComplete.contains(device.device_id), !cleanupPending.contains(device.device_id) else {
            throw CoreError.revocationIncomplete
        }
        _ = try ProtocolCodec.encode(device)
        revoked.remove(device.device_id)
        cleanupComplete.remove(device.device_id)
        devices[device.device_id] = device
    }
    public func all() -> [DeviceInfo] { devices.values.sorted { $0.device_id < $1.device_id } }
    public func textReceiver(_ id: String) throws -> DeviceInfo {
        guard let device = devices[id], device.role == .text_receiver || device.role == .both,
              device.capabilities.contains(.receive_text) else { throw CoreError.unavailableTarget }
        return device
    }
    /// Remove locally before suspending; retry revoke to retry external cleanup.
    /// Both cleanup operations are attempted even if the first fails.
    public func revoke(_ id: String) async throws {
        devices.removeValue(forKey: id)
        revoked.insert(id)
        cleanupComplete.remove(id)
        guard !cleanupPending.contains(id) else { throw CoreError.revocationIncomplete }
        cleanupPending.insert(id)
        defer { cleanupPending.remove(id) }
        var failure: (any Error)?
        do { try await revocation.deleteKey(deviceID: id) } catch { failure = error }
        do { try await revocation.dropRoom(deviceID: id) } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
        cleanupComplete.insert(id)
    }
}
