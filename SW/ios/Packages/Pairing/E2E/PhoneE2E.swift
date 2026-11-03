import Foundation
import Crypto
import Pairing
import Core
import VoiceRemoteProtocol

private struct TestClock: FocusClock { func nowMilliseconds() -> Int64 { 100_000 } }
/// Adversarial stale-ciphertext probe, never an application resend policy.
/// It captures only synthetic encrypted test packets and never prints them.
private actor CapturedTransport: PairingTransport {
    let inner: any PairingTransport
    var last = Data()
    init(_ inner: any PairingTransport) { self.inner = inner }
    func retainedSession() async { await inner.retainedSession() }
    func send(_ packet: Data) async throws { last = packet; try await inner.send(packet) }
    func receive() async throws -> Data { try await inner.receive() }
    func close() async { await inner.close() }
}
@main struct PhoneE2E {
    static func command() throws -> String {
        guard let line = readLine() else { throw PairingError.closedTransport }; return line
    }
    static func emit(_ value: String) { try! FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8)) }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw PairingError.invalidState }
        let mode = args[1], endpoint = args[2].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let invitation = try PairingInvitation(qr: Data(command().utf8), expectedAccount: "synthetic-e2e", clock: SystemPairingClock())
        let registry = PeerRegistry(store: InMemoryKeyStore()), keys = DeviceKeys(store: InMemoryKeyStore())
        let staticKey = try await keys.noiseKey()
        let client: RelayClient?
        if mode != "lan" {
            let route = try RelayRoute(account: invitation.payload.account_id, room: invitation.payload.relay_room_id, device: "phone")
            let relay = try RelayClient(origin: URL(string: endpoint[0])!, route: route,
                signingKey: await keys.relayKey(account: route.account, room: route.room), http: URLSessionRelayHTTP(),
                connector: LoopbackWebSocketConnector(), allowLoopback: true)
            try await relay.redeem(invitation); client = relay
        } else { client = nil }
        let port = mode == "preferred" ? UInt16(endpoint[1])! : mode == "lan" ? UInt16(endpoint[0])! : 0
        let openLAN: @Sendable () async throws -> any PairingTransport = {
            guard port != 0 else { throw PairingError.noMessage }
            return LANTransport(stream: try SocketStream(port: port))
        }
        let openRelay: (@Sendable () async throws -> any PairingTransport)? = client.map { client in
            { @Sendable in try await client.connect() }
        }
        let (opened, pending) = try await PreferredConnection.connect(lan: {
            let transport = try await openLAN()
            let pending = try await PairingConnection.initiate(invitation: invitation, staticKey: staticKey, clock: SystemPairingClock(), transport: transport)
            emit("PATH_LAN"); return (transport, pending)
        }, relay: openRelay.map { open in { @Sendable in
            let transport = try await open()
            let pending = try await PairingConnection.initiate(invitation: invitation, staticKey: staticKey, clock: SystemPairingClock(), transport: transport)
            emit("PATH_RELAY"); return (transport, pending)
        } })
        let transport = CapturedTransport(opened)
        let phrase = await pending.phrase; emit("PHRASE:" + phrase)
        guard try command() == "confirm" else { throw PairingError.confirmationRequired }
        let phone = DeviceInfo(account_id: "synthetic-e2e", device_id: "phone", display_name: "Synthetic e2e phone", platform: .ios, role: .text_receiver, capabilities: [.receive_text])
        try await pending.confirmLocal(displayedPhrase: phrase, device: phone, transport: transport)
        try await pending.receiveConfirmation(transport: transport)
        let session = try await pending.finish(registry: registry), peer = await session.peer
        var connection = PhoneConnection(session: session, transport: transport)
        func read(_ connection: PhoneConnection) -> Task<Void, Never> {
            Task { do { while !Task.isCancelled { _ = try await connection.receive() } } catch {} }
        }
        var reader = read(connection)
        emit("PAIRED")
        func text(_ segment: String, failure: Bool = false) -> DictationText {
            DictationText(account_id: "synthetic-e2e", segment_id: segment, revision: 1, state: .committed,
                target_device_id: "desktop", text: failure ? "Synthetic failure" : String(repeating: "🦀", count: 16384))
        }
        guard try command() == "dictate" else { throw PairingError.invalidState }
        try await connection.prepare()
        guard try await connection.insert(text("initial")).outcome == .inserted else { throw PairingError.invalidMessage }
        emit("DELIVERED")
        guard try await connection.insert(text("failure", failure: true)).outcome == .unavailable else { throw PairingError.invalidMessage }
        emit("FAILED_RETAIN_TEXT")
        let stale = await transport.last
        var replay: (any PairingTransport)?
        var next = try command()
        if mode == "relay" {
            var queued = 0
            while next == "queue" {
                if replay == nil { replay = try await client!.connect(); await replay!.retainedSession() }
                try await replay!.send(stale)
                queued += 1; emit("QUEUED_OLD_SESSION"); next = try command()
            }
            guard queued > 0 else { throw PairingError.invalidState }
        }
        guard next == "resume" else { throw PairingError.invalidState }
        reader.cancel(); await connection.close(); await replay?.close()
        let (active, resumed) = try await PreferredConnection.connect(lan: {
            let transport = try await openLAN()
            let session = try await SessionResume.initiate(staticKey: staticKey, registry: registry, peer: peer, localDeviceID: "phone", transport: transport)
            emit("RESUME_LAN"); return (transport, session)
        }, relay: client.map { client in { @Sendable in
            let transport = try await client.reconnect(registry: registry, peer: peer)
            let session = try await SessionResume.initiate(staticKey: staticKey, registry: registry, peer: peer, localDeviceID: "phone", transport: transport)
            emit("RESUME_RELAY"); return (transport, session)
        } })
        connection = PhoneConnection(session: resumed, transport: active); reader = read(connection)
        guard try await connection.reconcile(segmentID: "initial").outcome == .inserted else { throw PairingError.invalidMessage }
        emit("RECONCILED_WITHOUT_INSERTION")
        try await connection.prepare()
        // Deliberate adversarial replay of a known-inserted segment: the receiver
        // must answer from its durable claim even when LAN switched to relay.
        guard try await connection.insert(text("initial")).outcome == .inserted else { throw PairingError.invalidMessage }
        emit("SAME_SEGMENT_DEDUPLICATED")
        guard try await connection.reconcile(segmentID: "never-arrived").outcome == .unavailable else { throw PairingError.invalidMessage }
        guard try await connection.insert(text("never-arrived")).outcome == .inserted else { throw PairingError.invalidMessage }
        emit("NEVER_CLAIMED_SENT_ONCE")
        guard try await connection.insert(text("resumed")).outcome == .inserted else { throw PairingError.invalidMessage }
        emit("RESUMED")
        // Real phone Auto logic + generated wire decoding. Peer epochs differ by
        // centuries; the latest heartbeat must not refresh 61-second-old input.
        var picker = TargetPicker(accountID: "synthetic-e2e", phoneID: "phone", clock: TestClock())
        let desktop = peer.device
        let other = DeviceInfo(account_id: "synthetic-e2e", device_id: "other", display_name: "Synthetic other", platform: .linux, role: .text_receiver, capabilities: [.receive_text])
        for (device, epoch, age) in [(desktop.device_id, Int64(9007199254740991), Int64(61_000)), ("other", 0, 1000)] {
            let report = FocusReport(account_id: "synthetic-e2e", device_id: device, text_field_focused: true, last_activity_at: epoch, activity_age_ms: age)
            try picker.update(ProtocolCodec.decode(FocusReport.self, from: ProtocolCodec.encode(report)))
        }
        guard try picker.resolve(devices: [desktop, other]).device_id == "other",
              try picker.resolve(at: 161_001, devices: [desktop, other]).device_id == "phone" else { throw PairingError.invalidState }
        emit("AUTO_ACTIVITY_AGE_CLOCK_SKEW")
        guard try command() == "revoke" else { throw PairingError.invalidState }
        try await connection.send(.revoke(Revoke(account_id: "synthetic-e2e", device_id: "desktop", command_id: "e2e-revoke", idempotency_key: "e2e-revoke", revoked_at: try SystemPairingClock().nowMilliseconds())))
        do { try await connection.send(.dictationText(text("after-revoke"))); throw E2EFailure.revokedSendSucceeded }
        catch E2EFailure.revokedSendSucceeded { throw E2EFailure.revokedSendSucceeded } catch {}
        do { try await registry.require(peer); throw E2EFailure.enrollmentRetained }
        catch E2EFailure.enrollmentRetained { throw E2EFailure.enrollmentRetained } catch {}
        if let client {
            try await client.revoke(device: "desktop"); try await client.revoke(device: "phone")
            do { _ = try await client.reconnect(registry: registry, peer: peer); throw E2EFailure.revokedMemberConnected }
            catch RelayError.httpRefused(403) {}
        }
        reader.cancel(); await connection.close()
        emit("REVOKED_NEXT_MESSAGE_REJECTED")
    }
    enum E2EFailure: Error { case revokedSendSucceeded, enrollmentRetained, revokedMemberConnected }
}
