import Foundation
import Crypto
import Pairing
import VoiceRemoteProtocol

@main
struct PhoneE2E {
    static func command() throws -> String {
        guard let line = readLine() else { throw PairingError.closedTransport }; return line
    }
    static func emit(_ value: String) { try! FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8)) }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw PairingError.invalidState }
        let mode = args[1]; let endpoint = args[2]
        let qr = try Data(command().utf8)
        let invitation = try PairingInvitation(qr: qr, expectedAccount: "synthetic-e2e", clock: SystemPairingClock())
        let store = InMemoryKeyStore(); let registry = PeerRegistry(store: store); let keys = DeviceKeys(store: store)
        let staticKey = try await keys.noiseKey()
        let transport: any PairingTransport
        let client: RelayClient?
        if mode == "relay" {
            let route = try RelayRoute(account: invitation.payload.account_id, room: invitation.payload.relay_room_id, device: "phone")
            let relay = try RelayClient(origin: URL(string: endpoint)!, route: route,
                signingKey: await keys.relayKey(account: route.account, room: route.room), http: URLSessionRelayHTTP(),
                connector: LoopbackWebSocketConnector(), allowLoopback: true)
            try await relay.redeem(invitation)
            transport = try await relay.connect(); client = relay
        } else {
            transport = LANTransport(stream: try SocketStream(port: UInt16(endpoint)!)); client = nil
        }
        let pending = try await PairingConnection.initiate(invitation: invitation, staticKey: staticKey, clock: SystemPairingClock(), transport: transport)
        let phrase = await pending.phrase; emit("PHRASE:" + phrase)
        guard try command() == "confirm" else { throw PairingError.confirmationRequired }
        let phone = DeviceInfo(account_id: "synthetic-e2e", device_id: "phone", display_name: "Synthetic e2e phone", platform: .ios, role: .text_receiver, capabilities: [.receive_text])
        try await pending.confirmLocal(displayedPhrase: phrase, device: phone, transport: transport)
        try await pending.receiveConfirmation(transport: transport)
        var session = try await pending.finish(registry: registry)
        var active: any PairingTransport = transport
        let peer = await session.peer
        emit("PAIRED")
        guard try command() == "dictate" else { throw PairingError.invalidState }
        func text(_ segment: String) -> InnerMessage {
            .dictationText(DictationText(account_id: "synthetic-e2e", segment_id: segment, revision: 1, state: .committed, target_device_id: "desktop", text: "Synthetic e2e 🦀"))
        }
        try await session.send(text("initial"), transport: active); emit("SENT")
        var next = try command()
        if mode == "relay" {
            var queued = 0
            while next == "queue" {
                try await session.send(text("offline-old-session-\(queued)"), transport: active)
                queued += 1; emit("QUEUED_OLD_SESSION")
                next = try command()
            }
            guard queued > 0 else { throw PairingError.invalidState }
        }
        guard next == "resume" else { throw PairingError.invalidState }
        await session.close(transport: active)
        if let client { active = try await client.reconnect(registry: registry, peer: peer) }
        else { active = LANTransport(stream: try SocketStream(port: UInt16(endpoint)!)) }
        session = try await SessionResume.initiate(staticKey: staticKey, registry: registry, peer: peer, localDeviceID: "phone", transport: active)
        try await session.send(text("resumed"), transport: active); emit("RESUMED")
        guard try command() == "revoke" else { throw PairingError.invalidState }
        try await session.send(.revoke(Revoke(account_id: "synthetic-e2e", device_id: "desktop", command_id: "e2e-revoke", idempotency_key: "e2e-revoke", revoked_at: try SystemPairingClock().nowMilliseconds())), transport: active)
        do {
            try await session.send(text("after-revoke"), transport: active)
            throw E2EFailure.revokedSendSucceeded
        } catch E2EFailure.revokedSendSucceeded { throw E2EFailure.revokedSendSucceeded }
        catch {}
        do { try await registry.require(peer); throw E2EFailure.enrollmentRetained }
        catch E2EFailure.enrollmentRetained { throw E2EFailure.enrollmentRetained }
        catch {}
        if let client {
            try await client.revoke(device: "desktop")
            try await client.revoke(device: "phone")
            do {
                _ = try await client.reconnect(registry: registry, peer: peer)
                throw E2EFailure.revokedMemberConnected
            } catch RelayError.httpRefused(403) {}
        }
        emit("REVOKED_NEXT_MESSAGE_REJECTED")
    }
    enum E2EFailure: Error { case revokedSendSucceeded, enrollmentRetained, revokedMemberConnected }
}
