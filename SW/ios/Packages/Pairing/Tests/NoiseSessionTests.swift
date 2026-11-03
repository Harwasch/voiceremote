import Foundation
import XCTest
import Crypto
import VoiceRemoteProtocol
@testable import Pairing

func syntheticDevice(_ id: String = "desktop", account: String = "synthetic") -> DeviceInfo {
    DeviceInfo(account_id: account, device_id: id, display_name: "Synthetic", platform: .ios, role: .text_receiver, capabilities: [.receive_text])
}
func noisePair() async throws -> (NoiseSession, NoiseSession) {
    let a = NoiseXX(role: .initiator, staticKey: .init()); let b = NoiseXX(role: .responder, staticKey: .init())
    _ = try await b.readMessage(a.writeMessage()); _ = try await a.readMessage(b.writeMessage()); _ = try await b.readMessage(a.writeMessage())
    return try await (a.split(), b.split())
}
func enrolled(_ noise: NoiseSession, registry: PeerRegistry, device: DeviceInfo = syntheticDevice()) async throws -> Enrollment {
    try await registry.enroll(PairedPeer(device: device, publicKey: Data(repeating: 1, count: 32), roomID: "synthetic-room", session: noise))
}
func application(_ noise: NoiseSession, registry: PeerRegistry, local: String = "phone") async throws -> ApplicationSession {
    let peer = try await enrolled(noise, registry: registry)
    return ApplicationSession(noise: noise, registry: registry, peer: peer, localDeviceID: local)
}

final class NoiseSessionTests: XCTestCase, @unchecked Sendable {
    func testMaximumUnicodeRoundTripBothDirectionsAndSmallMessage() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (a, b) = try await noisePair()
            let left = try await application(a, registry: PeerRegistry(store: InMemoryKeyStore()))
            let right = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()))
            let (tx, rx) = InMemoryPairingTransport.pair()
            let message = InnerMessage.dictationText(DictationText(account_id: "synthetic", segment_id: "s", revision: 1, state: .committed, target_device_id: "desktop", text: String(repeating: "🦀", count: 16_384)))
            for (sender, receiver, out, input) in [(left, right, tx, rx), (right, left, rx, tx)] {
                try await sender.send(message, transport: out)
                let actual = try await receiver.receive(transport: input)
                XCTAssertEqual(actual, message)
            }
            try await left.send(.deviceInfo(syntheticDevice()), transport: tx)
            let small = try await right.receive(transport: rx)
            XCTAssertEqual(small, .deviceInfo(syntheticDevice()))
        }
    }
    func testFragmentGrammarBoundsAndInterleavingPoisonSession() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let fragment: (Int, Int, Data) -> Data = { Data([3]) + SessionWire.u32($0) + SessionWire.u32($1) + $2 }
            let bad: [[Data]] = [
                [Data([3])], [Data([3]) + Data(repeating: 0, count: 8)],
                [fragment(0, 0, Data([1]))], [fragment(2_097_153, 0, Data([1]))],
                [fragment(2, 1, Data([1]))], [fragment(1, 0, Data([1, 2]))],
                [fragment(3, 0, Data([1])), fragment(3, 0, Data([2]))], // overlap
                [fragment(3, 0, Data([1])), fragment(3, 2, Data([2]))], // gap
                [fragment(3, 0, Data([1])), fragment(2, 1, Data([2]))], // total changed
                [fragment(3, 0, Data([1])), Data("{}".utf8)], // interleaved JSON
                [fragment(1, 0, Data([255]))], // invalid UTF-8 only after assembly
                [Data()], [Data("{}".utf8)], [Data(repeating: 1, count: 10_985)]
            ]
            for (index, plaintexts) in bad.enumerated() {
                let (a, b) = try await noisePair(); let (tx, rx) = InMemoryPairingTransport.pair()
                let session = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()))
                for plain in plaintexts { try await tx.send(a.encrypt(plain)) }
                do { _ = try await session.receive(transport: rx, timeout: .seconds(1)); XCTFail("bad fragment \(index) accepted") } catch {}
                do { try await session.send(.deviceInfo(syntheticDevice()), transport: rx); XCTFail("poisoned session revived") } catch {}
            }
        }
    }
    func testUTF8ScalarCanStraddleFragments() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let bytes = try ProtocolCodec.encode(InnerMessage.dictationText(DictationText(account_id: "synthetic", segment_id: "s", revision: 1, state: .committed, target_device_id: "phone", text: "🦀")))
            let scalar = try XCTUnwrap(bytes.range(of: Data("🦀".utf8)))
            let split = scalar.lowerBound + 1
            let (a, b) = try await noisePair(); let (tx, rx) = InMemoryPairingTransport.pair()
            let session = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()))
            for (offset, chunk) in [(0, bytes.prefix(split)), (split, bytes.dropFirst(split))] {
                try await tx.send(a.encrypt(Data([3]) + SessionWire.u32(bytes.count) + SessionWire.u32(offset) + chunk))
            }
            let received = try await session.receive(transport: rx)
            XCTAssertEqual(received, try ProtocolCodec.decode(InnerMessage.self, from: bytes))
        }
    }
    func testAuthenticationReplayAndCrossAccountCloseApplication() async throws {
        try await testDeadline(seconds: 20) { [self] in
            for variant in 0..<3 {
                let (a, b) = try await noisePair(); let (tx, rx) = InMemoryPairingTransport.pair()
                let session = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()))
                let info = syntheticDevice(account: variant == 2 ? "other" : "synthetic")
                var packet = try await a.encrypt(ProtocolCodec.encode(info))
                if variant == 0 { packet[0] ^= 1 }
                try await tx.send(packet)
                if variant == 1 {
                    _ = try await session.receive(transport: rx)
                    try await tx.send(packet)
                }
                do { _ = try await session.receive(transport: rx); XCTFail("invalid account/auth/replay") } catch {}
                do { try await session.send(.deviceInfo(info), transport: rx); XCTFail("revived") } catch {}
            }
        }
    }
    func testIncompleteFragmentsTimeoutAndCancellationDiscardState() async throws {
        try await testDeadline(seconds: 20) { [self] in
            for cancel in [false, true] {
                let (a, b) = try await noisePair(); let (tx, rx) = InMemoryPairingTransport.pair()
                let session = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()))
                try await tx.send(a.encrypt(Data([3]) + SessionWire.u32(100) + SessionWire.u32(0) + Data([1])))
                let receive = Task { try await session.receive(transport: rx, timeout: .milliseconds(15)) }
                if cancel { receive.cancel() }
                do { _ = try await receive.value; XCTFail() } catch {}
                do { try await session.send(.deviceInfo(syntheticDevice()), transport: rx); XCTFail() } catch {}
            }
        }
    }
    func testRegistryReloadAndNewEnrollmentNeverReviveOldSessions() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let store = InMemoryKeyStore(); let registry = PeerRegistry(store: store)
            let (a, b) = try await noisePair(); let session = try await application(a, registry: registry)
            let peer = await session.peer
            let reloaded = try await PeerRegistry(store: store).lookup(publicKey: peer.publicKey)
            XCTAssertEqual(reloaded?.generation, peer.generation)
            try await PeerRegistry(store: store).require(peer)
            try await registry.revoke(peer)
            let replacement = try await enrolled(b, registry: registry)
            do { try await registry.revoke(peer); XCTFail("stale generation deleted replacement") } catch {}
            try await registry.require(replacement)
            let (tx, _) = InMemoryPairingTransport.pair()
            do { try await session.send(.deviceInfo(syntheticDevice()), transport: tx); XCTFail() } catch {}
            do { _ = try await SessionResume.initiate(staticKey: .init(), registry: registry, peer: peer, localDeviceID: "phone", transport: tx); XCTFail() } catch {}
        }
    }
    func testKeysPersistSeparatelyAndDelete() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let store = InMemoryKeyStore(); let keys = DeviceKeys(store: store)
            let first = try await keys.noiseKey(); let second = try await keys.noiseKey()
            XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
            let id = try await keys.relayDeviceID(account: "synthetic", room: "room")
            let reloadedID = try await DeviceKeys(store: store).relayDeviceID(account: "synthetic", room: "room")
            XCTAssertEqual(id, reloadedID)
            try RelayRoute.validateID(id)
            let relay = try await keys.relayKey(account: "synthetic", room: "room")
            let reloaded = try await DeviceKeys(store: store).relayKey(account: "synthetic", room: "room")
            XCTAssertEqual(relay.rawRepresentation, reloaded.rawRepresentation)
            XCTAssertNotEqual(first.rawRepresentation, relay.rawRepresentation)
            let anotherRoom = try await keys.relayKey(account: "synthetic", room: "other")
            XCTAssertNotEqual(relay.rawRepresentation, anotherRoom.rawRepresentation)
            store.delete("noise-identity"); XCTAssertNil(store.get("noise-identity"))
            store.put("noise-identity", value: Data([1]))
            do { _ = try await keys.noiseKey(); XCTFail("corrupt key replaced silently") } catch {}
        }
    }
    func testResumeRejectsWrongStaticPayloadAndReadyHashAndTimeout() async throws {
        try await testDeadline(seconds: 20) { [self] in
            for variant in 0..<4 {
                let registry = PeerRegistry(store: InMemoryKeyStore()); let (a, _) = try await noisePair()
                let key = Curve25519.KeyAgreement.PrivateKey()
                let peer = try await registry.enroll(PairedPeer(device: syntheticDevice(), publicKey: key.publicKey.rawRepresentation, roomID: "room", session: a))
                let (tx, rx) = InMemoryPairingTransport.pair()
                let responder = Task {
                    do {
                        let state = NoiseXX(role: .responder, staticKey: variant == 0 ? .init() : key, prologue: SessionWire.resumePrologue(account: "synthetic", room: "room"))
                        _ = try await state.readMessage(rx.receive())
                        if variant == 3 { _ = try await rx.receive(); return }
                        try await rx.send(state.writeMessage(payload: variant == 1 ? Data([1]) : Data()))
                        _ = try await state.readMessage(rx.receive())
                        let noise = try await state.split()
                        try await rx.send(noise.encrypt(Data([2]) + Data(repeating: 0, count: 32)))
                    } catch {}
                }
                do { _ = try await SessionResume.initiate(staticKey: .init(), registry: registry, peer: peer, localDeviceID: "phone", transport: tx, timeout: .milliseconds(20)); XCTFail("invalid resume \(variant)") } catch {}
                await responder.value
            }
        }
    }
}

private actor FailedWriter: PairingTransport {
    var writes = 0
    var closed = false
    func send(_ frame: Data) throws { writes += 1; throw PairingError.closedTransport }
    func receive() throws -> Data { throw PairingError.closedTransport }
    func close() { closed = true }
}
private struct RevokeOnReceive: PairingTransport {
    let source: InMemoryPairingTransport
    let registry: PeerRegistry
    let peer: Enrollment
    func send(_ frame: Data) async throws { try await source.send(frame) }
    func receive() async throws -> Data {
        let packet = try await source.receive()
        try await registry.revoke(peer)
        return packet
    }
    func close() async { await source.close() }
}
extension NoiseSessionTests {
    func testFailedSendNeverRetriesConsumedNonce() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (a, _) = try await noisePair()
            let session = try await application(a, registry: PeerRegistry(store: InMemoryKeyStore()))
            let transport = FailedWriter()
            for _ in 0..<2 {
                do { try await session.send(.deviceInfo(syntheticDevice()), transport: transport); XCTFail() } catch {}
            }
            let writes = await transport.writes; let closed = await transport.closed
            XCTAssertEqual(writes, 1); XCTAssertTrue(closed)
        }
    }
    func testRevocationDuringReceivePreventsDelivery() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (a, b) = try await noisePair(); let registry = PeerRegistry(store: InMemoryKeyStore())
            let session = try await application(b, registry: registry)
            let peer = await session.peer; let (tx, rx) = InMemoryPairingTransport.pair()
            try await tx.send(a.encrypt(ProtocolCodec.encode(syntheticDevice())))
            let transport = RevokeOnReceive(source: rx, registry: registry, peer: peer)
            do { _ = try await session.receive(transport: transport); XCTFail("revoked in-flight message delivered") } catch {}
        }
    }
    func testOrderedPathSwitchPreservesNonceState() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (a, b) = try await noisePair()
            let left = try await application(a, registry: PeerRegistry(store: InMemoryKeyStore()))
            let right = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()))
            // Independent carriers represent LAN -> relay -> LAN; no state split or
            // replay while switching. Production adapters share this same boundary.
            for _ in 0..<3 {
                let (tx, rx) = InMemoryPairingTransport.pair()
                try await left.send(.deviceInfo(syntheticDevice()), transport: tx)
                let message = try await right.receive(transport: rx)
                XCTAssertEqual(message, .deviceInfo(syntheticDevice()))
            }
        }
    }
}

extension NoiseSessionTests {
    func testConfirmedLegacyEnrollmentMigrationDoesNotRotateExistingGeneration() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let registry = PeerRegistry(store: InMemoryKeyStore())
            let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            let device = syntheticDevice()
            try await registry.restoreConfirmed(device: device, publicKey: key, roomID: "legacy-room")
            let lookup = try await registry.lookup(publicKey: key)
            let retained = try XCTUnwrap(lookup)
            try await registry.restoreConfirmed(device: device, publicKey: key, roomID: "legacy-room")
            try await registry.require(retained)
            do {
                try await registry.restoreConfirmed(device: device, publicKey: key, roomID: "other-room")
                XCTFail("mismatched migration overwrote enrollment")
            } catch {}
            try await registry.require(retained)
        }
    }
}
