import Foundation
import XCTest
import Crypto
import VoiceRemoteProtocol
@testable import Pairing

private actor QueueSocket: WebSocket {
    let input: InMemoryPairingTransport
    var sent: [String] = []
    init(_ input: InMemoryPairingTransport) { self.input = input }
    func send(text: String) async throws { sent.append(text); try await input.send(Data(text.utf8)) }
    func receive() async throws -> WebSocketMessage { .text(String(decoding: try await input.receive(), as: UTF8.self)) }
    func ping() {}
    func close() async { await input.close() }
}

final class NoiseEpochTests: XCTestCase, @unchecked Sendable {
    func testQueuedOldSessionAndHandshakeRepliesCannotPoisonFreshXX() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let room = String(repeating: "a", count: 32)
            let phoneRoute = try RelayRoute(account: "synthetic", room: room, device: "phone")
            let deskRoute = try RelayRoute(account: "synthetic", room: room, device: "desktop")
            let desktopKey = Curve25519.KeyAgreement.PrivateKey()
            let phoneKey = Curve25519.KeyAgreement.PrivateKey()
            func exchange(_ phone: RelayTransport, _ desktop: RelayTransport) async throws -> (NoiseSession, NoiseSession) {
                let a = NoiseXX(role: .initiator, staticKey: phoneKey)
                let b = NoiseXX(role: .responder, staticKey: desktopKey)
                async let responder: NoiseSession = {
                    _ = try await b.readMessage(desktop.receive())
                    try await desktop.send(b.writeMessage())
                    _ = try await b.readMessage(desktop.receive())
                    return try await b.split()
                }()
                let initiator = try await withTransportDeadline(phone, timeout: .seconds(2)) {
                    try await phone.send(a.writeMessage())
                    _ = try await a.readMessage(phone.receive())
                    try await phone.send(a.writeMessage())
                    return try await a.split()
                }
                return try await (initiator, responder)
            }
            let (a, b) = InMemoryPairingTransport.pair()
            let oldPhone = QueueSocket(a); let oldDesktop = QueueSocket(b)
            let pt = RelayTransport(socket: oldPhone, route: phoneRoute, droppedFrames: 0)
            let dt = RelayTransport(socket: oldDesktop, route: deskRoute, droppedFrames: 0)
            let (pn, dn) = try await exchange(pt, dt)
            try await pt.send(pn.encrypt(Data("synthetic stale application".utf8)))
            try await dt.send(dn.encrypt(Data("synthetic stale reply".utf8)))
            let queuedPhone = await oldDesktop.sent
            let queuedDesktop = await oldPhone.sent
            await pt.close(); await dt.close()
            let (c, d) = InMemoryPairingTransport.pair()
            // Connect replays the offline queue in exactly the real Worker's order,
            // including old handshakes, not merely application ciphertext.
            for text in queuedPhone { try await d.send(Data(text.utf8)) }
            let retained = RelayRecords.encode(6, epoch: Data(repeating: 0, count: 64), payload: Data(repeating: 1, count: 32))
            try await d.send(ProtocolCodec.encode(RelayCiphertext(account_id: "synthetic", room_id: room, sender_device_id: "desktop", ciphertext: retained.base64EncodedString())))
            try await c.send(ProtocolCodec.encode(RelayCiphertext(account_id: "synthetic", room_id: room, sender_device_id: "phone", ciphertext: retained.base64EncodedString())))
            for text in queuedDesktop { try await c.send(Data(text.utf8)) }
            let freshPhone = RelayTransport(socket: QueueSocket(c), route: phoneRoute, droppedFrames: 0)
            let freshDesktop = RelayTransport(socket: QueueSocket(d), route: deskRoute, droppedFrames: 0)
            _ = try await exchange(freshPhone, freshDesktop)
            await freshPhone.close(); await freshDesktop.close()
        }
    }
}

extension NoiseEpochTests {
    func testRetainedNoiseSessionMovesFromLANToRelayAndBack() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (a, b) = try await noisePair()
            let left = try await application(a, registry: PeerRegistry(store: InMemoryKeyStore()))
            let right = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()))
            let (lanOut, lanIn) = InMemoryPairingTransport.pair()
            let message = InnerMessage.deviceInfo(syntheticDevice())
            try await left.send(message, transport: lanOut)
            let first = try await right.receive(transport: lanIn); XCTAssertEqual(first, message)
            let room = String(repeating: "a", count: 32)
            let (out, input) = InMemoryPairingTransport.pair()
            let relayOut = RelayTransport(socket: QueueSocket(out), route: try RelayRoute(account: "synthetic", room: room, device: "phone"), droppedFrames: 0)
            let relayIn = RelayTransport(socket: QueueSocket(input), route: try RelayRoute(account: "synthetic", room: room, device: "desktop"), droppedFrames: 0)
            try await left.send(message, transport: relayOut)
            let second = try await right.receive(transport: relayIn); XCTAssertEqual(second, message)
            try await right.send(message, transport: relayIn)
            let reverse = try await left.receive(transport: relayOut); XCTAssertEqual(reverse, message)
            try await left.send(message, transport: lanOut)
            let third = try await right.receive(transport: lanIn); XCTAssertEqual(third, message)
            await relayOut.close(); await relayIn.close()
        }
    }
}
