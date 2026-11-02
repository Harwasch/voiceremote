import Foundation
import XCTest
import Crypto
import VoiceRemoteProtocol
@testable import Pairing

func hex(_ value: String) throws -> Data {
    guard value.count % 2 == 0 else { throw PairingError.invalidMessage }
    var result = Data(); var index = value.startIndex
    while index < value.endIndex {
        let end = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<end], radix: 16) else { throw PairingError.invalidMessage }
        result.append(byte); index = end
    }
    return result
}
private struct VectorSet: Decodable { let vectors: [NoiseVector] }
private struct NoiseVector: Decodable {
    let protocol_name: String
    let init_prologue: String
    let init_static: String
    let init_ephemeral: String
    let resp_prologue: String
    let resp_static: String
    let resp_ephemeral: String
    let handshake_hash: String
    let messages: [Message]
    struct Message: Decodable { let payload: String; let ciphertext: String }
}

final class NoiseTests: XCTestCase, @unchecked Sendable {
    func testRFC7693ABCAndOfficialBLAKE2BoundaryVectors() throws {
        XCTAssertEqual(BLAKE2s.hash(Data("abc".utf8)), try hex("508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"))
        for (length, digest) in [
            (0, "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"),
            (3, "e8f91c6ef232a041452ab0e149070cdd7dd1769e75b3a5921be37876c45c9900"),
            (64, "56f34e8b96557e90c1f24b52d0c89d51086acf1b00f634cf1dde9233b8eaaa3e"),
            (65, "1b53ee94aaf34e4b159d48de352c7f0661d0a40edff95a0b1639b4090e974472"),
            (255, "f03f5789d3336b80d002d59fdf918bdb775b00956ed5528e86aa994acb38fe2d")
        ] { XCTAssertEqual(BLAKE2s.hash(Data((0..<length).map(UInt8.init))), try hex(digest)) }
    }
    private func check(_ vector: NoiseVector) async throws {
        let initiator = try NoiseXX(role: .initiator,
            staticKey: .init(rawRepresentation: hex(vector.init_static)),
            ephemeralKey: .init(rawRepresentation: hex(vector.init_ephemeral)), prologue: hex(vector.init_prologue))
        let responder = try NoiseXX(role: .responder,
            staticKey: .init(rawRepresentation: hex(vector.resp_static)),
            ephemeralKey: .init(rawRepresentation: hex(vector.resp_ephemeral)), prologue: hex(vector.resp_prologue))
        XCTAssertGreaterThanOrEqual(vector.messages.count, 3)
        for index in 0..<3 {
            let v = vector.messages[index]
            let writer = index == 1 ? responder : initiator
            let reader = index == 1 ? initiator : responder
            let message = try await writer.writeMessage(payload: hex(v.payload))
            XCTAssertEqual(message, try hex(v.ciphertext), "handshake message \(index + 1)")
            let plain = try await reader.readMessage(message)
            XCTAssertEqual(plain, try hex(v.payload))
        }
        let initHash = try await initiator.handshakeHash(); let respHash = try await responder.handshakeHash()
        XCTAssertEqual(initHash, try hex(vector.handshake_hash)); XCTAssertEqual(respHash, initHash)
        let a = try await initiator.split(); let b = try await responder.split()
        for index in 3..<vector.messages.count {
            let v = vector.messages[index]
            let writer = index % 2 == 0 ? a : b
            let reader = index % 2 == 0 ? b : a
            let encrypted = try await writer.encrypt(hex(v.payload))
            XCTAssertEqual(encrypted, try hex(v.ciphertext), "transport message \(index - 2)")
            let plain = try await reader.decrypt(encrypted)
            XCTAssertEqual(plain, try hex(v.payload))
        }
        do { _ = try await initiator.split(); XCTFail("split reused") } catch {}
    }
    func testOfficialCacophonyXXVector() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cacophony-xx", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode(VectorSet.self, from: Data(contentsOf: url)).vectors
        XCTAssertEqual(vectors.count, 1)
        for vector in vectors { try await check(vector) }
    }
    /// The desktop task can land shared vectors after this branch was created.
    /// Recognized Cacophony-shaped XX files are run automatically, never silently skipped.
    func testSharedSYSNoiseVectorsWhenPresent() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("SYS/protocol/vectors/noise")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Shared SYS Noise vectors are not on this base; bundled Cacophony vector runs independently")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var checked = 0
        for file in files {
            let data = try Data(contentsOf: file)
            if let set = try? JSONDecoder().decode(VectorSet.self, from: data) {
                for vector in set.vectors where vector.protocol_name == "Noise_XX_25519_ChaChaPoly_BLAKE2s" {
                    try await check(vector); checked += 1
                }
            } else if let vector = try? JSONDecoder().decode(NoiseVector.self, from: data), vector.protocol_name == "Noise_XX_25519_ChaChaPoly_BLAKE2s" {
                try await check(vector); checked += 1
            } else if let vector = try? JSONDecoder().decode(DesktopVector.self, from: data) {
                try await checkDesktop(vector); checked += 1
            } else { XCTFail("Unrecognized shared Noise vector: \(file.lastPathComponent)") }
        }
        XCTAssertGreaterThan(checked, 0, "Shared Noise directory needs a usable XX vector")
    }
    func testTamperedHandshakePoisonsStateAndRejectsMalformedDH() async throws {
        let a = NoiseXX(role: .initiator, staticKey: .init())
        let b = NoiseXX(role: .responder, staticKey: .init())
        _ = try await b.readMessage(a.writeMessage())
        var second = try await b.writeMessage(); second[second.count - 1] ^= 1
        do { _ = try await a.readMessage(second); XCTFail() } catch {}
        do { _ = try await a.writeMessage(); XCTFail() } catch {}
        do { _ = try await a.split(); XCTFail() } catch {}
        let invalid = NoiseXX(role: .responder, staticKey: .init())
        _ = try await invalid.readMessage(Data(repeating: 0, count: 32))
        do { _ = try await invalid.writeMessage(); XCTFail("all-zero DH accepted") } catch {}
        let short = NoiseXX(role: .responder, staticKey: .init())
        do { _ = try await short.readMessage(Data(repeating: 0, count: 31)); XCTFail() } catch {}
    }
    func testTransportAuthenticationReplayDirectionsAndSizes() async throws {
        let a = NoiseXX(role: .initiator, staticKey: .init()); let b = NoiseXX(role: .responder, staticKey: .init())
        _ = try await b.readMessage(a.writeMessage()); _ = try await a.readMessage(b.writeMessage())
        _ = try await b.readMessage(a.writeMessage())
        let left = try await a.split(); let right = try await b.split()
        let encrypted = try await left.encrypt(Data("synthetic".utf8))
        var damaged = encrypted; damaged[0] ^= 1
        do { _ = try await right.decrypt(damaged); XCTFail() } catch {}
        let decoded = try await right.decrypt(encrypted)
        XCTAssertEqual(decoded, Data("synthetic".utf8))
        do { _ = try await right.decrypt(encrypted); XCTFail("replay accepted") } catch {}
        do { _ = try await left.decrypt(encrypted); XCTFail("reflected ciphertext accepted") } catch {}
        do { _ = try await left.encrypt(Data(repeating: 0, count: 65_520)); XCTFail() } catch {}
        let max = try await left.encrypt(Data(repeating: 0, count: 65_519))
        let maxPlain = try await right.decrypt(max)
        XCTAssertEqual(maxPlain.count, 65_519)
        await left.close()
        do { _ = try await left.encrypt(Data()); XCTFail() } catch {}
    }
}

private struct DesktopVector: Decodable {
    let pattern: String
    let initiator_static_private_hex: String
    let responder_static_private_hex: String
    let initiator_ephemeral_private_hex: String
    let responder_ephemeral_private_hex: String
    let qr_payload: PairingPayload
    let prologue_hex: String
    let handshake_messages_hex: [String]
    let handshake_hash_hex: String
    let verification_phrase: String
    let initiator_confirmation_plaintext_hex: String
    let responder_confirmation_plaintext_hex: String
    let initiator_confirmation_ciphertext_hex: String
    let responder_confirmation_ciphertext_hex: String
    let application_plaintext: String
    let application_ciphertext_hex: String
}

extension NoiseTests {
    private func checkDesktop(_ vector: DesktopVector) async throws {
        XCTAssertEqual(vector.pattern, "Noise_XX_25519_ChaChaPoly_BLAKE2s")
        let invitation = try PairingInvitation(qr: ProtocolCodec.encode(vector.qr_payload),
            expectedAccount: vector.qr_payload.account_id, clock: TestClock(now: vector.qr_payload.expires_at - 120_000))
        XCTAssertEqual(invitation.prologue, try hex(vector.prologue_hex))
        let initiator = try NoiseXX(role: .initiator,
            staticKey: .init(rawRepresentation: hex(vector.initiator_static_private_hex)),
            ephemeralKey: .init(rawRepresentation: hex(vector.initiator_ephemeral_private_hex)), prologue: invitation.prologue)
        let responder = try NoiseXX(role: .responder,
            staticKey: .init(rawRepresentation: hex(vector.responder_static_private_hex)),
            ephemeralKey: .init(rawRepresentation: hex(vector.responder_ephemeral_private_hex)), prologue: invitation.prologue)
        XCTAssertEqual(vector.handshake_messages_hex.count, 3)
        for index in 0..<3 {
            let payload = index == 2 ? invitation.token : Data()
            let sender = index == 1 ? responder : initiator
            let receiver = index == 1 ? initiator : responder
            let message = try await sender.writeMessage(payload: payload)
            XCTAssertEqual(message, try hex(vector.handshake_messages_hex[index]))
            let plain = try await receiver.readMessage(message)
            XCTAssertEqual(plain, payload)
        }
        let hash = try await initiator.handshakeHash(); let reverseHash = try await responder.handshakeHash()
        let remote = try await initiator.remoteStaticKey()
        XCTAssertEqual(remote, invitation.desktopKey)
        XCTAssertEqual(hash, try hex(vector.handshake_hash_hex)); XCTAssertEqual(reverseHash, hash)
        XCTAssertEqual(try VerificationPhrase.derive(handshakeHash: hash), vector.verification_phrase)
        let a = try await initiator.split(); let b = try await responder.split()
        // Use the fixture's exact JSON bytes. No cross-language JSON canonical form is assumed.
        for (sender, receiver, plainHex, encryptedHex) in [
            (a, b, vector.initiator_confirmation_plaintext_hex, vector.initiator_confirmation_ciphertext_hex),
            (b, a, vector.responder_confirmation_plaintext_hex, vector.responder_confirmation_ciphertext_hex)
        ] {
            let plain = try hex(plainHex)
            XCTAssertEqual(plain.first, 1); XCTAssertEqual(Data(plain.dropFirst().prefix(32)), hash)
            let device = try ProtocolCodec.decode(DeviceInfo.self, from: Data(plain.dropFirst(33)))
            XCTAssertEqual(device.account_id, invitation.payload.account_id)
            let encrypted = try await sender.encrypt(plain)
            XCTAssertEqual(encrypted, try hex(encryptedHex))
            let decoded = try await receiver.decrypt(encrypted)
            XCTAssertEqual(decoded, plain)
        }
        let application = Data(vector.application_plaintext.utf8)
        _ = try ProtocolCodec.decode(DictationText.self, from: application)
        let encrypted = try await a.encrypt(application)
        XCTAssertEqual(encrypted, try hex(vector.application_ciphertext_hex))
        let decoded = try await b.decrypt(encrypted)
        XCTAssertEqual(decoded, application)
    }
    func testDesktopSnowPairingVectorIncludingConfirmationsAndApplication() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "desktop-xx-pairing", withExtension: "json", subdirectory: "Fixtures"))
        try await checkDesktop(JSONDecoder().decode(DesktopVector.self, from: Data(contentsOf: url)))
    }
}
