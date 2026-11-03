import Foundation
import Crypto
import VoiceRemoteProtocol

/// Endpoint secrets and enrollment generations; implementations never log values.
public protocol KeyStore: Sendable {
    func get(_ name: String) throws -> Data?
    func put(_ name: String, value: Data) throws
    func delete(_ name: String) throws
}

public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func get(_ name: String) -> Data? { lock.withLock { values[name] } }
    public func put(_ name: String, value: Data) { lock.withLock { values[name] = value } }
    public func delete(_ name: String) { lock.withLock { _ = values.removeValue(forKey: name) } }
}

/// Use one owner per store so load/create cannot race. Relay and Noise keys use
/// separate names and algorithms. A fresh relay identity is created per room.
public actor DeviceKeys {
    private let store: any KeyStore
    public init(store: any KeyStore) { self.store = store }
    public func noiseKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let bytes = try store.get("noise-identity") { return try .init(rawRepresentation: bytes) }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try store.put("noise-identity", value: key.rawRepresentation)
        return key
    }
    public func relayKey(account: String, room: String) throws -> Curve25519.Signing.PrivateKey {
        let context = SessionWire.resumePrologue(account: account, room: room)
        let name = "relay-" + SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        if let bytes = try store.get(name) { return try .init(rawRepresentation: bytes) }
        let key = Curve25519.Signing.PrivateKey()
        try store.put(name, value: key.rawRepresentation)
        return key
    }
    public func relayDeviceID(account: String, room: String) throws -> String {
        let context = SessionWire.resumePrologue(account: account, room: room)
        let name = "relay-device-" + SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        if let bytes = try store.get(name) {
            guard let id = String(data: bytes, encoding: .utf8) else { throw PairingError.invalidState }
            try RelayRoute.validateID(id)
            return id
        }
        let id = UUID().uuidString.lowercased()
        try store.put(name, value: Data(id.utf8))
        return id
    }
}

public struct Enrollment: Codable, Sendable {
    public let device: DeviceInfo
    public let publicKey: Data
    public let roomID: String
    public let generation: UUID
    var storageName: String { "peer-" + SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined() }
}

/// Retain one registry for an endpoint. Reload persisted generation on every I/O;
/// re-enrollment cannot revive a revoked session.
public actor PeerRegistry {
    private let store: any KeyStore
    public init(store: any KeyStore) { self.store = store }
    public func enroll(_ peer: PairedPeer) throws -> Enrollment {
        guard peer.publicKey.count == 32 else { throw PairingError.invalidMessage }
        _ = try ProtocolCodec.encode(peer.device)
        let result = Enrollment(device: peer.device, publicKey: peer.publicKey, roomID: peer.roomID, generation: UUID())
        try store.put(result.storageName, value: JSONEncoder().encode(result))
        return result
    }
    public func require(_ peer: Enrollment) throws {
        guard let current = try lookup(publicKey: peer.publicKey) else { throw PairingError.invalidState }
        guard current.generation == peer.generation, current.publicKey == peer.publicKey,
              current.roomID == peer.roomID, current.device == peer.device else { throw PairingError.invalidState }
    }
    public func lookup(publicKey: Data) throws -> Enrollment? {
        guard publicKey.count == 32 else { throw PairingError.invalidMessage }
        let name = "peer-" + SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        guard let bytes = try store.get(name) else { return nil }
        let peer = try JSONDecoder().decode(Enrollment.self, from: bytes)
        guard peer.publicKey == publicKey else { throw PairingError.keyMismatch }
        _ = try ProtocolCodec.encode(peer.device)
        return peer
    }
    public func revoke(_ peer: Enrollment) throws {
        if try lookup(publicKey: peer.publicKey) == nil { return }
        try require(peer)
        try store.delete(peer.storageName)
    }
}

#if canImport(Security)
import Security

/// AfterFirstUnlock permits background audio/session work while locked after
/// the first unlock since boot. ThisDeviceOnly prevents migration/backup restore;
/// synchronizable=false explicitly excludes iCloud Keychain. Never BeforeFirstUnlock.
public struct KeychainStore: KeyStore {
    private let service: String
    public init(service: String) { self.service = service }
    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: name,
         kSecAttrSynchronizable as String: false]
    }
    public func get(_ name: String) throws -> Data? {
        var q = query(name); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw PairingError.invalidState }
        return data
    }
    public func put(_ name: String, value: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(name) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(name).merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw PairingError.invalidState }
    }
    public func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingError.invalidState }
    }
}
#endif
