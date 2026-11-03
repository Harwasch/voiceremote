import Foundation
import Security
import Crypto
import Policy
import Core

/// ThisDeviceOnly credentials never enter UserDefaults, files, logs or exports.
@MainActor enum SecureStore {
    /// One-time migration keeps the existing local account and all its stores.
    /// A changed defaults value fails closed before any shared data is opened.
    static func fixedAccount(defaults: UserDefaults) throws -> String {
        let pinned = try load("installation-account").map { String(decoding: $0, as: UTF8.self) }
        let account = try InstallationAccount.resolve(requested: defaults.string(forKey: "accountID"), pinned: pinned)
        if pinned == nil { try save(Data(account.utf8), key: "installation-account") }
        defaults.set(account, forKey: "accountID")
        return account
    }
    static func load(_ key: String) throws -> Data? {
        var query = base(key); query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PolicyError.auditUnavailable }
        return data
    }
    static func save(_ data: Data, key: String) throws {
        let query = base(key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PolicyError.auditUnavailable }
        } else if status != errSecSuccess { throw PolicyError.auditUnavailable }
    }
    static func delete(_ key: String) throws {
        let status = SecItemDelete(base(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PolicyError.auditUnavailable }
    }
    static func loadOrCreateKey(_ key: String) throws -> Data {
        if let data = try load(key) { return data }
        let data = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        try save(data, key: key); return data
    }
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "VoiceRemote",
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
}
@MainActor final class KeychainCheckpoint: AuditCheckpointStore {
    func load() throws -> AuditCheckpoint {
        guard let data = try SecureStore.load("audit-checkpoint") else { return .empty }
        return try JSONDecoder().decode(AuditCheckpoint.self, from: data)
    }
    func save(_ value: AuditCheckpoint) throws { try SecureStore.save(JSONEncoder().encode(value), key: "audit-checkpoint") }
    func loadPending() throws -> AuditPending? {
        guard let data = try SecureStore.load("audit-pending") else { return nil }
        return try JSONDecoder().decode(AuditPending.self, from: data)
    }
    func savePending(_ value: AuditPending?) throws {
        if let value { try SecureStore.save(JSONEncoder().encode(value), key: "audit-pending") }
        else { try SecureStore.delete("audit-pending") }
    }
}
