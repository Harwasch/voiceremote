// Purpose: protected archive state and recoverable app audit slots.
// Inputs: audit-archive v2; portable adapters tested, Apple storage/UI unverified.
import Foundation
import Observation
import Crypto
import AppModel
import Policy

/// Keys, exact sealed pending intent, and independent anchors are one atomic
/// ThisDeviceOnly Keychain item per account/room. The private marker detects a
/// missing item; it never bootstraps trust from relay data.
@MainActor final class KeychainArchiveSlot: AuditArchiveAnchorStore {
    private struct Material: Codable { let key: Data; var state: AuditArchiveState }
    private let name: String
    private var material: Material
    let cipher: PhoneArchiveCipher
    init(root: URL, account: String, room: String, create: Bool) throws {
        name = "archive:" + PayloadDigest.sha256(try JSONEncoder().encode([account, room]))
        let marker = root.appendingPathComponent(PayloadDigest.sha256(Data(name.utf8)) + ".archive-anchor")
        if let data = try SecureStore.load(name) {
            material = try JSONDecoder().decode(Material.self, from: data)
            guard material.state.anchor.account == account, material.state.anchor.room == room else { throw PolicyError.tampered }
        } else {
            guard create, !FileManager.default.fileExists(atPath: marker.path) else { throw PolicyError.auditUnavailable }
            material = Material(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
                state: AuditArchiveState(anchor: AuditArchiveAnchor(account: account, room: room), health: .unverified))
            try SecureStore.save(JSONEncoder().encode(material), key: name)
        }
        cipher = try PhoneArchiveCipher(key: material.key)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data("Protected archive anchor required".utf8).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    func loadArchive() throws -> AuditArchiveState {
        guard let bytes = try SecureStore.load(name) else { throw PolicyError.auditUnavailable }
        let value = try JSONDecoder().decode(Material.self, from: bytes)
        guard value.key == material.key else { throw PolicyError.tampered }
        return value.state
    }
    func saveArchive(_ state: AuditArchiveState) throws {
        guard state.anchor.account == material.state.anchor.account, state.anchor.room == material.state.anchor.room else { throw PolicyError.tampered }
        let value = Material(key: material.key, state: state)
        try SecureStore.save(JSONEncoder().encode(value), key: name); material = value
    }
}

@MainActor @Observable final class AuditRecoveryController {
    var message = "We couldn’t check your saved data. Restore a verified copy to continue. Your original data has been kept."
    var busy = false
    var rooms: [String] = []
    var selectedRoom = ""
    func loadRooms() {
        #if DEBUG
        if UIDemo.requested { rooms = []; return }
        #endif
        do {
            let root = try Self.rootURL(), account = try SecureStore.fixedAccount(defaults: .standard)
            let peers = try PeerStore(url: root.appendingPathComponent("peers-" + PayloadDigest.sha256(Data(account.utf8)) + ".json"), accountID: account)
            rooms = Array(Set(peers.active.filter { $0.relayOrigin != nil && $0.suspended != true }.map(\.roomID))).sorted()
            if !rooms.contains(selectedRoom) { selectedRoom = rooms.first ?? "" }
        } catch { rooms = [] }
    }
    private static func rootURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("VoiceRemote", isDirectory: true)
    }
    static func activeSlot() throws -> String {
        guard let bytes = try SecureStore.load("active-audit-slot") else { return "audit" }
        let slot = String(decoding: bytes, as: UTF8.self)
        guard slot == "audit" || UUID(uuidString: slot) != nil else { throw PolicyError.tampered }
        return slot
    }
    static func journalURL(root: URL, slot: String) -> URL {
        root.appendingPathComponent(slot == "audit" ? "audit.jsonl" : "audit-" + slot + ".jsonl")
    }
    static func checkpoints(root: URL, slot: String) throws -> KeychainCheckpoint {
        let checkpoints = KeychainCheckpoint(slot: slot)
        let marker = root.appendingPathComponent(slot + ".audit-anchor")
        if try SecureStore.load(slot + "-checkpoint") == nil {
            let url = journalURL(root: root, slot: slot)
            var prefix: Data?
            if FileManager.default.fileExists(atPath: url.path) {
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                prefix = try file.read(upToCount: 1) ?? Data()
            }
            let initial = try AuditCheckpointBootstrap.initial(markerExists: FileManager.default.fileExists(atPath: marker.path),
                journal: prefix, pendingExists: checkpoints.loadPending() != nil, legacySlot: slot == "audit")
            try checkpoints.save(initial)
        }
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data("Independent checkpoint required".utf8).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return checkpoints
    }
    func recover() async -> Bool {
        #if DEBUG
        if UIDemo.requested { message = "No verified copy is available in this demo. Nothing was changed."; return false }
        #endif
        guard !busy else { return false }; busy = true; defer { busy = false }
        do {
            let root = try Self.rootURL(), sourceSlot = try Self.activeSlot()
            let account = try SecureStore.fixedAccount(defaults: .standard)
            guard let phone = UserDefaults.standard.string(forKey: "phoneID") else { throw PolicyError.invalid }
            let source = try FileAuditJournal(url: Self.journalURL(root: root, slot: sourceSlot))
            let checkpoints = KeychainCheckpoint(slot: sourceSlot)
            let peers = try PeerStore(url: root.appendingPathComponent("peers-" + PayloadDigest.sha256(Data(account.utf8)) + ".json"), accountID: account)
            let link = ComputerLink(accountID: account, phoneID: phone, store: peers)
            // A stable destination is pinned before any biometric or network wait.
            let destinationKey = "audit-recovery-destination:" + sourceSlot
            let destination: String
            if let bytes = try SecureStore.load(destinationKey) { destination = String(decoding: bytes, as: UTF8.self) }
            else { destination = UUID().uuidString; try SecureStore.save(Data(destination.utf8), key: destinationKey) }
            guard UUID(uuidString: destination) != nil else { throw PolicyError.tampered }
            let destinationCheckpoints = try Self.checkpoints(root: root, slot: destination)
            let destinationJournal = try FileAuditJournal(url: Self.journalURL(root: root, slot: destination))
            let room = selectedRoom.isEmpty ? link.archiveRooms.first : selectedRoom
            guard let room, link.archiveRooms.contains(room) else { throw PolicyError.auditUnavailable }
            let archive = try KeychainArchiveSlot(root: root, account: account, room: room, create: false)
            _ = try await PhoneArchiveRecovery.restore(client: link.archiveClient(room: room), cipher: archive.cipher,
                archive: archive, source: source, checkpoints: checkpoints, destination: destinationJournal,
                destinationCheckpoints: destinationCheckpoints, account: account, actor: phone,
                sessionID: "audit-recovery", biometric: LocalAuthenticationBiometric())
            try SecureStore.save(Data(destination.utf8), key: "active-audit-slot")
            message = "Your saved copy was checked and restored. Your original data has been kept."
            return true
        } catch {
            message = "We couldn’t restore your data. A verified saved copy, this phone’s security information, and Face ID or your passcode are needed. Your original data has been kept. Recording and approvals stay paused."
            return false
        }
    }
}
