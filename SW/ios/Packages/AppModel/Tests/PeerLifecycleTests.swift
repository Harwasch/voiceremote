import Foundation
import Testing
import Crypto
import Core
import Pairing
import VoiceRemoteProtocol
@testable import AppModel

@Test func reconnectPinsStaticKeyAndRequiresEncryptedReady() async throws {
    let phone = Curve25519.KeyAgreement.PrivateKey(), desktop = Curve25519.KeyAgreement.PrivateKey()
    let (a, b) = InMemoryPairingTransport.pair()
    let responder = Task {
        let handshake = NoiseXX(role: .responder, staticKey: desktop, prologue: PeerResume.prologue(accountID: "fixture", roomID: "fixture-room"))
        _ = try await handshake.readMessage(b.receive())
        try await b.send(handshake.writeMessage())
        _ = try await handshake.readMessage(b.receive())
        #expect(try await handshake.remoteStaticKey() == phone.publicKey.rawRepresentation)
        let hash = try await handshake.handshakeHash()
        let session = try await handshake.split()
        try await b.send(session.encrypt(Data([2]) + hash))
        return session
    }
    let session = try await PeerResume.initiate(accountID: "fixture", roomID: "fixture-room", localPrivateKey: phone.rawRepresentation,
        expectedRemoteKey: desktop.publicKey.rawRepresentation, transport: a)
    let remote = try await responder.value
    let cipher = try await session.encrypt(Data("synthetic".utf8))
    #expect(try await remote.decrypt(cipher) == Data("synthetic".utf8))
    await a.close()
}

@Test @MainActor func failedRemoteRevokeStillErasesKeysAndPersistsTombstone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PeerStore(url: root.appendingPathComponent("peers.json"), accountID: "fixture")
    let device = DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Fixture", platform: .windows,
        role: .text_receiver, capabilities: [.receive_text])
    try store.enroll(device, roomID: "room")
    var erased = false, closed = false
    do {
        try await PeerRevocation.perform(deviceID: "pc", accountID: "fixture", store: store,
            send: { data in
                let revoke = try ProtocolCodec.decode(Revoke.self, from: data)
                #expect(revoke.device_id == "pc"); #expect(store.active.isEmpty)
                throw PairingError.closedTransport
            }, erase: { erased = true }, close: { closed = true }, now: 1_000_000)
        Issue.record("Notification failure was hidden")
    } catch {}
    #expect(erased && closed)
    #expect(store.active.isEmpty); #expect(store.records.first?.notificationPending == true)
}

@Test func settingsWithdrawalSurvivesFileReopen() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
    var settings = AppSettings(); settings.cloudConsent = true; try store.save(settings)
    settings.cloudConsent = false; try store.save(settings)
    #expect(try SettingsStore(url: store.url).load()?.cloudConsent == false)
}

@Test @MainActor func reopenedPeersRestoreCoreRegistryAndRevokedPeersStayRemoved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("peers.json")
    let store = try PeerStore(url: url, accountID: "fixture")
    let device = DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Fixture", platform: .windows,
        role: .text_receiver, capabilities: [.receive_text])
    try store.enroll(device, roomID: "fixture-room")
    let registry = Core.DeviceRegistry(accountID: "fixture", revocation: TargetSpy())
    let reopened = try PeerStore(url: url, accountID: "fixture")
    _ = try await reopened.restore(registry: registry, keyAvailable: { _ in true })
    #expect(await registry.all() == [device])
    try reopened.markRevoked(deviceID: "pc", notificationPending: true)
    let next = Core.DeviceRegistry(accountID: "fixture", revocation: TargetSpy())
    _ = try await PeerStore(url: url, accountID: "fixture").restore(registry: next, keyAvailable: { _ in true })
    #expect(await next.all().isEmpty)
}

@Test func reconnectRejectsChangedPeerKeyAndClosesTransport() async throws {
    let phone = Curve25519.KeyAgreement.PrivateKey(), desktop = Curve25519.KeyAgreement.PrivateKey()
    let (a, b) = InMemoryPairingTransport.pair()
    let responder = Task {
        let handshake = NoiseXX(role: .responder, staticKey: desktop, prologue: PeerResume.prologue(accountID: "fixture", roomID: "room"))
        _ = try await handshake.readMessage(b.receive())
        try await b.send(handshake.writeMessage())
    }
    do {
        _ = try await PeerResume.initiate(accountID: "fixture", roomID: "room", localPrivateKey: phone.rawRepresentation,
            expectedRemoteKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, transport: a)
        Issue.record("Changed key accepted")
    } catch { #expect(error as? PairingError == .keyMismatch) }
    try await responder.value
}

@Test @MainActor func pairingConfirmedDeviceIsReturnedOnlyAfterBackendConfirmation() async throws {
    final class Backend: ComputerPairing {
        var confirms = 0
        func begin(_ code: String, role: DeviceInfoRole) async throws -> String { "one two three four" }
        func confirm(_ phrase: String) async throws -> DeviceInfo {
            confirms += 1
            return DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Fixture", platform: .windows,
                role: .text_receiver, capabilities: [.receive_text])
        }
        func cancel() async {}
    }
    let backend = Backend()
    let subject = PairingFlow(backend: backend)
    #expect(await subject.confirm() == nil); #expect(backend.confirms == 0)
    await subject.begin("fixture")
    #expect(subject.phrase != nil); #expect(backend.confirms == 0)
    #expect(await subject.confirm()?.device_id == "pc"); #expect(backend.confirms == 1)
    #expect(subject.phrase == nil)
}
