import Foundation
import XCTest
import Crypto
import VoiceRemoteProtocol
@testable import Pairing

#if os(Linux) || os(macOS)
/// Real desktop core in a separate process. No fixture-only stand-in. stdout is
/// bounded framing containing synthetic QR/packets; never production data.
private final class RustPeer: PairingTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let reader = DispatchQueue(label: "interop.read")
    private let writer = DispatchQueue(label: "interop.write")
    init(fromPhone: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // A helper owns/reaps the complete cargo process group. SIGTERM may
        // be inherited blocked from Swift's worker threads; unblock it before
        // spawning. A stuck cargo/peer cannot retain stdout for hours.
        process.arguments = ["python3", "-u", "-c", boundedPeerProcessScript, "cargo", "run", "--quiet", "--manifest-path", root.appendingPathComponent("SW/desktop/Cargo.toml").path,
                              "-j4", "-p", "voiceremote-core", "--example", "phone_interop", "--"] + (fromPhone ? ["--revoke-from-phone"] : [])
        process.standardInput = input; process.standardOutput = output
        try process.run()
    }
    func line(_ prefix: String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.async { [self] in
                    do {
                        var bytes = Data()
                        while true {
                            guard let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty else { throw PairingError.closedTransport }
                            if next.first == 10 { break }
                            guard bytes.count < 150_000 else { throw PairingError.messageTooLarge }
                            bytes += next
                        }
                        let text = String(decoding: bytes, as: UTF8.self)
                        guard text.hasPrefix(prefix + ":") else { throw PairingError.invalidMessage }
                        continuation.resume(returning: String(text.dropFirst(prefix.count + 1)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { if self.process.isRunning { self.process.terminate() } }
    }
    func receive() async throws -> Data { try await hex(line("packet")) }
    func send(_ frame: Data) async throws {
        let bytes = Data(("packet:" + frame.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.async { [self] in
                do { try input.fileHandleForWriting.write(contentsOf: bytes); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    // Keep the control pipe readable after a logical session revoke. Explicit
    // shutdown below owns process lifetime; production transports close sockets.
    func close() async {}
    func shutdown() { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close() }
    func waitForSuccess() async throws {
        let done = try await line("done")
        XCTAssertEqual(done, "handshake phrase fragments resume revoke verified")
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in process.waitUntilExit(); continuation.resume() }
        }
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

final class NoiseInteropTests: XCTestCase, @unchecked Sendable {
    private func exchange(fromPhone: Bool) async throws {
        let rust = try RustPeer(fromPhone: fromPhone); defer { rust.shutdown() }
        let qr = try await hex(rust.line("qr"))
        let invitation = try PairingInvitation(qr: qr, expectedAccount: "synthetic", clock: TestClock(now: 1))
        let keys = DeviceKeys(store: InMemoryKeyStore()); let key = try await keys.noiseKey()
        let registry = PeerRegistry(store: InMemoryKeyStore())
        let pending = try await PairingConnection.initiate(invitation: invitation, staticKey: key, clock: TestClock(now: 1), transport: rust)
        let phrase = try await rust.line("phrase")
        let phonePhrase = await pending.phrase; XCTAssertEqual(phrase, phonePhrase)
        let device = DeviceInfo(account_id: "synthetic", device_id: "phone", display_name: "Synthetic phone", platform: .ios, role: .text_receiver, capabilities: [.receive_text])
        try await pending.confirmLocal(displayedPhrase: phrase, device: device, transport: rust)
        try await pending.receiveConfirmation(transport: rust)
        let paired = try await pending.finish(registry: registry)
        let peer = await paired.peer
        let text = DictationText(account_id: "synthetic", segment_id: "synthetic-segment", revision: 1, state: .committed, target_device_id: "desktop", text: String(repeating: "🦀", count: 16_384))
        try await paired.send(.dictationText(text), transport: rust)
        let outcome = try await paired.receive(transport: rust)
        guard case .dictationOutcome(let acknowledgement) = outcome else { return XCTFail("insertion outcome expected") }
        XCTAssertEqual(acknowledgement.outcome, .inserted)
        let response = try await paired.receive(transport: rust)
        guard case .dictationText(let returned) = response else { return XCTFail("dictation expected") }
        XCTAssertEqual(returned.text, text.text); XCTAssertEqual(returned.target_device_id, "phone")
        let resumed = try await SessionResume.initiate(staticKey: key, registry: registry, peer: peer, localDeviceID: "phone", transport: rust)
        try await resumed.send(.deviceInfo(device), transport: rust)
        let metadata = try await resumed.receive(transport: rust)
        guard case .deviceInfo(let desktop) = metadata else { return XCTFail("resumed metadata expected") }
        XCTAssertEqual(desktop.device_id, "desktop")
        if fromPhone {
            try await resumed.send(.revoke(Revoke(account_id: "synthetic", device_id: "desktop", command_id: "synthetic-revoke", idempotency_key: "synthetic-idempotency", revoked_at: 1)), transport: rust)
            do { try await resumed.send(.deviceInfo(device), transport: rust); XCTFail("phone sent after outgoing revoke") } catch {}
            do { try await registry.require(peer); XCTFail("phone retained enrollment after outgoing revoke") } catch {}
            do { _ = try await SessionResume.initiate(staticKey: key, registry: registry, peer: peer, localDeviceID: "phone", transport: rust); XCTFail("phone resumed after outgoing revoke") } catch {}
        } else {
            let revoke = try await resumed.receive(transport: rust)
            guard case .revoke = revoke else { return XCTFail("revoke expected") }
            do { try await registry.require(peer); XCTFail("phone retained revoked peer") } catch {}
            do { try await resumed.send(.deviceInfo(device), transport: rust); XCTFail("revoked session sent") } catch {}
        }
        try await rust.waitForSuccess()
    }
    func testRustSwiftExchangeAndDesktopRevoke() async throws { try await testDeadline(seconds: 120) { [self] in try await exchange(fromPhone: false) } }
    func testRustSwiftExchangeAndPhoneRevoke() async throws { try await testDeadline(seconds: 120) { [self] in try await exchange(fromPhone: true) } }
}
#endif
