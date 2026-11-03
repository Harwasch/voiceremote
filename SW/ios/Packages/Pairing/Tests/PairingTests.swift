import Foundation
import XCTest
import Crypto
import VoiceRemoteProtocol
@testable import Pairing

struct TestClock: PairingClock { let now: Int64; func nowMilliseconds() -> Int64 { now } }
private struct FailingClock: PairingClock { func nowMilliseconds() throws -> Int64 { throw PairingError.expiredQR } }
private func info(_ id: String, account: String = "synthetic") -> DeviceInfo {
    DeviceInfo(account_id: account, device_id: id, display_name: id, platform: .ios, role: .text_receiver, capabilities: [.receive_text])
}
private func qr(key: Data, expires: Int64 = 120_001, account: String = "synthetic") throws -> Data {
    try ProtocolCodec.encode(PairingPayload(account_id: account, desktop_public_key: key.base64EncodedString(),
        one_use_token: Data(repeating: 7, count: 32).base64EncodedString(), expires_at: expires, relay_room_id: "test-room"))
}

final class PairingTests: XCTestCase, @unchecked Sendable {
    func testQRStrictParsingKeySizeAccountExpiryAndTrustedClock() throws {
        let bytes = try qr(key: Data(repeating: 1, count: 32))
        _ = try PairingInvitation(qr: bytes, expectedAccount: "synthetic", clock: TestClock(now: 1))
        for now: Int64 in [0, 120_001, 120_002, -1] {
            XCTAssertThrowsError(try PairingInvitation(qr: bytes, expectedAccount: "synthetic", clock: TestClock(now: now)))
        }
        XCTAssertThrowsError(try PairingInvitation(qr: bytes, expectedAccount: "other", clock: TestClock(now: 1)))
        XCTAssertThrowsError(try PairingInvitation(qr: bytes, expectedAccount: "synthetic", clock: FailingClock()))
        XCTAssertThrowsError(try PairingInvitation(qr: qr(key: Data([1])), expectedAccount: "synthetic", clock: TestClock(now: 1)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["extra"] = "unexpected"
        XCTAssertThrowsError(try PairingInvitation(qr: JSONSerialization.data(withJSONObject: object), expectedAccount: "synthetic", clock: TestClock(now: 1)))
    }
    func testDesktopPrologueAndPhraseDefinition() throws {
        let invitation = try PairingInvitation(qr: qr(key: Data(repeating: 1, count: 32)), expectedAccount: "synthetic", clock: TestClock(now: 1))
        let expected = Data("voiceremote/pair/v1\0".utf8) + (try hex("00000009")) + Data("synthetic".utf8)
            + (try hex("00000009")) + Data("test-room".utf8) + Data(repeating: 1, count: 32) + (try hex("000000000001d4c1"))
        XCTAssertEqual(invitation.prologue, expected)
        let hash = try hex("6c4c56cf71612f72d05ceb96c0155e6f4ea54a26b504c93de632a2db4a49d200")
        XCTAssertEqual(try VerificationPhrase.derive(handshakeHash: hash), "goldmoth elmmoth ferngoat maplepuma")
        XCTAssertThrowsError(try VerificationPhrase.derive(handshakeHash: Data()))
    }
    /// Desktop-shaped responder: verifies message payloads, QR-bound prologue,
    /// raw one-use token in msg3, and encrypted [1 || hash || DeviceInfo] confirmations.
    private func accept(invitation: PairingInvitation, key: Curve25519.KeyAgreement.PrivateKey,
                        transport: any PairingTransport) async throws -> PairingConfirmation {
        let state = NoiseXX(role: .responder, staticKey: key, prologue: invitation.prologue)
        let first = try await state.readMessage(transport.receive())
        XCTAssertTrue(first.isEmpty)
        try await transport.send(state.writeMessage())
        let token = try await state.readMessage(transport.receive())
        XCTAssertEqual(token, Data(repeating: 7, count: 32))
        return try await PairingConfirmation(handshake: state, invitation: invitation)
    }
    func testInMemoryPairingRequiresBothConfirmationsThenExchangesText() async throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let invitation = try PairingInvitation(qr: qr(key: key.publicKey.rawRepresentation), expectedAccount: "synthetic", clock: TestClock(now: 1))
        let (phone, desktop) = InMemoryPairingTransport.pair()
        async let incoming = accept(invitation: invitation, key: key, transport: desktop)
        let outgoing = try await PairingConnection.initiate(invitation: invitation, staticKey: .init(), clock: TestClock(now: 1), transport: phone)
        let pendingDesktop = try await incoming
        let phrase = await outgoing.phrase; let desktopPhrase = await pendingDesktop.phrase
        XCTAssertEqual(phrase, desktopPhrase); XCTAssertEqual(phrase.split(separator: " ").count, 4)
        do { _ = try await outgoing.finish(); XCTFail() } catch {}
        try await outgoing.confirmLocal(displayedPhrase: phrase, device: info("phone"), transport: phone)
        try await pendingDesktop.receiveConfirmation(transport: desktop)
        do { _ = try await outgoing.finish(); XCTFail("remote confirmation missing") } catch {}
        try await pendingDesktop.confirmLocal(displayedPhrase: phrase, device: info("desktop"), transport: desktop)
        try await outgoing.receiveConfirmation(transport: phone)
        let peer = try await outgoing.finish(); let reverse = try await pendingDesktop.finish()
        XCTAssertEqual(peer.device.device_id, "desktop"); XCTAssertEqual(peer.publicKey, key.publicKey.rawRepresentation)
        let encrypted = try await peer.session.encrypt(Data("synthetic text".utf8))
        let plain = try await reverse.session.decrypt(encrypted)
        XCTAssertEqual(plain, Data("synthetic text".utf8))
        do { _ = try await outgoing.finish(); XCTFail("enrolled twice") } catch {}
    }
    func testWrongQRKeyStopsBeforeTokenAndClosesTransport() async throws {
        let real = Curve25519.KeyAgreement.PrivateKey()
        let invitation = try PairingInvitation(qr: qr(key: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation), expectedAccount: "synthetic", clock: TestClock(now: 1))
        let (phone, desktop) = InMemoryPairingTransport.pair()
        let responder = Task {
            let state = NoiseXX(role: .responder, staticKey: real, prologue: invitation.prologue)
            _ = try await state.readMessage(desktop.receive())
            try await desktop.send(state.writeMessage())
            do { _ = try await desktop.receive(); XCTFail("token sent to mismatched static key") } catch {}
        }
        do { _ = try await PairingConnection.initiate(invitation: invitation, staticKey: .init(), clock: TestClock(now: 1), transport: phone); XCTFail() } catch {}
        try await responder.value
    }
    func testPhraseMismatchAbortsAndRejectsFurtherUse() async throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let invitation = try PairingInvitation(qr: qr(key: key.publicKey.rawRepresentation), expectedAccount: "synthetic", clock: TestClock(now: 1))
        let (a, b) = InMemoryPairingTransport.pair()
        async let accepted = accept(invitation: invitation, key: key, transport: b)
        let pending = try await PairingConnection.initiate(invitation: invitation, staticKey: .init(), clock: TestClock(now: 1), transport: a)
        _ = try await accepted
        do { try await pending.confirmLocal(displayedPhrase: "wrong phrase", device: info("phone"), transport: a); XCTFail() } catch {}
        do { _ = try await pending.finish(); XCTFail() } catch {}
        do { try await a.send(Data()); XCTFail() } catch {}
    }
    func testTransportCloseAndCancellationUnblockReceivers() async throws {
        let (a, b) = InMemoryPairingTransport.pair()
        let waiting = Task { try await a.receive() }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail() } catch {}
        let next = Task { try await b.receive() }
        await a.close()
        do { _ = try await next.value; XCTFail() } catch {}
    }
}

private actor ReceiveSpy: PairingTransport {
    let underlying: InMemoryPairingTransport
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    init(_ underlying: InMemoryPairingTransport) { self.underlying = underlying }
    func send(_ frame: Data) async throws { try await underlying.send(frame) }
    func receive() async throws -> Data {
        started = true; observer?.resume(); observer = nil
        return try await underlying.receive()
    }
    func waitUntilReceiving() async {
        if !started { await withCheckedContinuation { observer = $0 } }
    }
    func close() async { await underlying.close() }
}

extension PairingTests {
    private func rawPending() async throws -> (PairingConfirmation, NoiseSession, Data) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let invitation = try PairingInvitation(qr: qr(key: key.publicKey.rawRepresentation), expectedAccount: "synthetic", clock: TestClock(now: 1))
        let a = NoiseXX(role: .initiator, staticKey: .init(), prologue: invitation.prologue)
        let b = NoiseXX(role: .responder, staticKey: key, prologue: invitation.prologue)
        _ = try await b.readMessage(a.writeMessage()); _ = try await a.readMessage(b.writeMessage())
        _ = try await b.readMessage(a.writeMessage(payload: invitation.token))
        let hash = try await b.handshakeHash()
        return (try await PairingConfirmation(handshake: a, invitation: invitation), try await b.split(), hash)
    }
    func testMalformedNegativeWrongHashAndCrossAccountConfirmationsPoisonEnrollment() async throws {
        for variant in 0..<5 {
            let (pending, sender, hash) = try await rawPending()
            let (a, b) = InMemoryPairingTransport.pair()
            let plain: Data
            switch variant {
            case 0: plain = Data()
            case 1: plain = Data([0]) + hash + (try ProtocolCodec.encode(info("desktop")))
            case 2: plain = Data([1]) + Data(repeating: 0, count: 32) + (try ProtocolCodec.encode(info("desktop")))
            case 3: plain = Data([1]) + hash + (try ProtocolCodec.encode(info("desktop", account: "other")))
            default: plain = Data([1]) + hash + Data("{}".utf8)
            }
            try await b.send(sender.encrypt(plain))
            do { try await pending.receiveConfirmation(transport: a); XCTFail("invalid confirmation \(variant)") } catch {}
            do { _ = try await pending.finish(); XCTFail() } catch {}
            do { try await pending.confirmLocal(displayedPhrase: pending.phrase, device: info("phone"), transport: a); XCTFail() } catch {}
        }
    }
    func testConcurrentRemoteConfirmationAndDuplicateLocalConfirmationAreRejected() async throws {
        let (pending, sender, hash) = try await rawPending()
        let (a, b) = InMemoryPairingTransport.pair(); let spy = ReceiveSpy(a)
        let receiving = Task { try await pending.receiveConfirmation(transport: spy) }
        await spy.waitUntilReceiving()
        do { try await pending.receiveConfirmation(transport: spy); XCTFail("concurrent receive accepted") } catch {}
        try await b.send(sender.encrypt(Data([1]) + hash + (try ProtocolCodec.encode(info("desktop")))))
        try await receiving.value
        let phrase = await pending.phrase
        try await pending.confirmLocal(displayedPhrase: phrase, device: info("phone"), transport: a)
        do { try await pending.confirmLocal(displayedPhrase: phrase, device: info("phone"), transport: a); XCTFail("duplicate local confirm accepted") } catch {}
        _ = try await pending.finish()
    }
    func testDuplicateDeviceIdentityCannotFinish() async throws {
        let (pending, sender, hash) = try await rawPending()
        let (a, b) = InMemoryPairingTransport.pair()
        try await b.send(sender.encrypt(Data([1]) + hash + (try ProtocolCodec.encode(info("same")))))
        try await pending.receiveConfirmation(transport: a)
        try await pending.confirmLocal(displayedPhrase: pending.phrase, device: info("same"), transport: a)
        do { _ = try await pending.finish(); XCTFail("duplicate identity accepted") } catch {}
    }
    func testInitiationCancellationAndTimeoutClosePendingIO() async throws {
        let invitation = try PairingInvitation(qr: qr(key: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation), expectedAccount: "synthetic", clock: TestClock(now: 1))
        let (a, b) = InMemoryPairingTransport.pair(); let spy = ReceiveSpy(a)
        let initiating = Task { try await PairingConnection.initiate(invitation: invitation, staticKey: .init(), clock: TestClock(now: 1), transport: spy) }
        await spy.waitUntilReceiving(); initiating.cancel()
        do { _ = try await initiating.value; XCTFail() } catch {}
        do { _ = try await b.receive(); XCTFail("transport still open") } catch {}
        let (c, d) = InMemoryPairingTransport.pair()
        do { _ = try await PairingConnection.initiate(invitation: invitation, staticKey: .init(), clock: TestClock(now: 1), transport: c, timeout: .milliseconds(10)); XCTFail() } catch {}
        do { _ = try await d.receive(); XCTFail("timeout left transport open") } catch {}
    }
}

extension PairingTests {
    func testQRRejectsCRLFAndControlCombiningClustersInEncodedKeyMaterial() throws {
        let valid = try qr(key: Data(repeating: 1, count: 32))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for field in ["desktop_public_key", "one_use_token"] {
            for cluster in ["\r\n", "a\r\nb", "\n\u{0301}", "\u{0000}\u{0301}"] {
                var corrupted = object
                let encoded = try XCTUnwrap(object[field] as? String)
                corrupted[field] = String(encoded.prefix(20)) + cluster + String(encoded.dropFirst(20))
                let bytes = try JSONSerialization.data(withJSONObject: corrupted)
                XCTAssertThrowsError(try ProtocolCodec.decode(PairingPayload.self, from: bytes))
                XCTAssertThrowsError(try PairingInvitation(qr: bytes, expectedAccount: "synthetic", clock: TestClock(now: 1)))
            }
        }
    }
}
