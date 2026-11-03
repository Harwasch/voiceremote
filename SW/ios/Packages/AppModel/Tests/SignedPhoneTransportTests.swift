// Purpose: cross-check exact signing bytes on push/archive production adapters.
// Inputs: generated ephemeral keys, synthetic metadata, in-memory HTTP/socket.
// Verification: real Ed25519/AEAD; live relay/APNs and Apple networking unverified.
import Foundation
import Testing
import Crypto
import Pairing
import Policy
import VoiceRemoteProtocol
@testable import AppModel

private actor SignedPhoneHTTP: RelayHTTP {
    let key: Curve25519.Signing.PublicKey
    let room = String(repeating: "a", count: 32)
    var pending: [String: (String, String, Int64)] = [:]
    var blocks: [AuditArchiveBlock] = []
    var writes: [AuditArchiveBlock] = []
    var loseAcknowledgement = true
    var writerRefused = false
    init(key: Curve25519.Signing.PublicKey) { self.key = key }
    func refuseWriter() { writerRefused = true }
    func array(_ value: [Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) }
    func verify(_ request: RelayRequest, operation: String) throws {
        let nonce = try #require(request.headers["X-Relay-Challenge"])
        let consumed = pending.removeValue(forKey: nonce)
        let expected = try #require(consumed)
        #expect(expected.0 == operation)
        #expect(expected.1 == Data(SHA256.hash(data: request.body)).base64EncodedString())
        let message = try array(["voiceremote-relay-auth-v1", "fixture", room, "phone", operation, expected.1, nonce, expected.2])
        #expect(key.isValidSignature(try #require(Data(base64Encoded: request.headers["X-Relay-Signature"] ?? "")), for: message))
    }
    func perform(_ request: RelayRequest) async throws -> RelayResponse {
        if request.url.lastPathComponent == "challenge" {
            let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: String])
            let proof = try array(["voiceremote-relay-challenge-v1", "fixture", room, Data(SHA256.hash(data: request.body)).base64EncodedString()])
            #expect(key.isValidSignature(try #require(Data(base64Encoded: request.headers["X-Relay-Signature"] ?? "")), for: proof))
            let operation = try #require(body["operation"]), hash = try #require(body["body_sha256"])
            let nonce = Data(UUID().uuidString.utf8.prefix(32)).base64EncodedString()
            let now = Int64(Date().timeIntervalSince1970 * 1000), expiry = now + 30_000
            pending[nonce] = (operation, hash, expiry)
            let message = try array(["voiceremote-relay-auth-v1", "fixture", room, "phone", operation, hash, nonce, expiry])
            return RelayResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["challenge": nonce,
                "message": String(decoding: message, as: UTF8.self), "server_time": now, "expires_at": expiry]))
        }
        let operation = request.url.path.contains("/archive/") ? "archive/" + request.url.lastPathComponent : request.url.lastPathComponent
        try verify(request, operation: operation)
        #expect(request.headers["Cache-Control"] == "no-store")
        if writerRefused { return RelayResponse(status: 403, body: Data(#"{"error":"archive_writer_mismatch"}"#.utf8)) }
        switch operation {
        case "archive/append":
            let block = try ProtocolCodec.decode(AuditArchiveBlock.self, from: request.body)
            writes.append(block)
            if blocks.isEmpty { blocks.append(block) } else { #expect(blocks[0] == block) }
            if loseAcknowledgement { loseAcknowledgement = false; throw PairingError.closedTransport }
            return RelayResponse(status: 200, body: Data("{}".utf8))
        case "archive/read":
            let read = try ProtocolCodec.decode(AuditArchiveRead.self, from: request.body)
            return RelayResponse(status: 200, body: try ProtocolCodec.encode(AuditArchivePage(account_id: read.account_id,
                room_id: read.room_id, blocks: Array(blocks.dropFirst(Int(read.sequence))), epoch: read.epoch)))
        default: throw PairingError.invalidMessage
        }
    }
}
private actor PushSocket: WebSocket {
    var messages: [String] = []
    var pinged = false
    var closed = false
    var incoming: [String] = []
    func enqueue(_ frames: [String]) { incoming += frames }
    func send(text: String) throws { guard !closed else { throw PairingError.closedTransport }; messages.append(text) }
    func receive() -> WebSocketMessage {
        guard !closed, !incoming.isEmpty else { return .closed }
        return .text(incoming.removeFirst())
    }
    func ping() { pinged = true }
    func close() { closed = true }
}
private actor PushConnector: WebSocketConnector {
    let http: SignedPhoneHTTP
    let socket: PushSocket
    private var live: PushSocket?
    private(set) var connections = 0
    private(set) var queued: [String] = []
    func queue(_ frame: String) { queued.append(frame) }
    init(http: SignedPhoneHTTP, socket: PushSocket) { self.http = http; self.socket = socket }
    func connect(_ request: RelayRequest) async throws -> WebSocketUpgrade {
        #expect(request.url.scheme == "wss"); #expect(request.url.query == nil)
        try await http.verify(request, operation: "connect")
        if let live { await live.close() } // Production room.ts replaces this device.
        let next = connections == 0 ? socket : PushSocket()
        connections += 1; live = next
        await next.enqueue(queued); queued = [] // Same destructive drain as room.ts.
        return WebSocketUpgrade(socket: next, headers: [:])
    }
}
@MainActor private final class SignedArchiveStore: AuditArchiveAnchorStore {
    var value = AuditArchiveState(anchor: AuditArchiveAnchor(account: "fixture", room: String(repeating: "a", count: 32)))
    func loadArchive() -> AuditArchiveState { value }
    func saveArchive(_ value: AuditArchiveState) { self.value = value }
}
@Test @MainActor func signedPhoneArchiveRetriesExactSealedIntentAndReadsBackWithRealAEAD() async throws {
    let key = Curve25519.Signing.PrivateKey(), socket = PushSocket()
    let http = SignedPhoneHTTP(key: key.publicKey), origin = URL(string: "https://synthetic.invalid")!
    let member = try RelayClient(origin: origin, route: RelayRoute(account: "fixture", room: String(repeating: "a", count: 32), device: "phone"),
        signingKey: key, http: http, connector: PushConnector(http: http, socket: socket))
    let client = try PhoneArchiveClient(member: member, origin: origin, http: http), store = SignedArchiveStore()
    let log = try AuditLog(journal: Journal(), checkpoints: Checkpoint(), retention: AuditRetention())
    // A gate denial creates real audit metadata through the public authority API.
    let gate = try PolicyGate(audit: log, biometric: Bio(), clock: { 1_000_000 })
    _ = gate.transition(requestID: UUID(), to: .cancelled)
    let cipher = try PhoneArchiveCipher(key: Data(repeating: 3, count: 32))
    do { _ = try await AuditArchive.replicate(log: log, client: client, cipher: cipher, store: store, now: 1_000_000); Issue.record("Expected lost ACK") }
    catch { #expect(store.value.pending != nil) }
    let intent = try #require(store.value.pending?.block)
    _ = try await AuditArchive.replicate(log: log, client: client, cipher: cipher, store: store, now: 1_000_001)
    #expect(store.value.health == .verified); #expect(store.value.pending == nil)
    #expect(await http.writes == [intent, intent])
    await http.refuseWriter()
    do { try await client.append(intent); Issue.record("Writer refusal was ignored") }
    catch AuditArchiveFailure.writerMismatch {} catch { Issue.record("Wrong typed writer refusal") }
    #expect(await http.pending.isEmpty)
}

@Test func phonePushRegistrationUsesMemberProofAndOnlyRoutingMetadata() async throws {
    let key = Curve25519.Signing.PrivateKey(), socket = PushSocket()
    let http = SignedPhoneHTTP(key: key.publicKey), origin = URL(string: "https://synthetic.invalid")!
    let connector = PushConnector(http: http, socket: socket)
    let tracked = WakeSocketConnector(base: connector)
    let route = try RelayRoute(account: "fixture", room: String(repeating: "a", count: 32), device: "phone")
    let member = try RelayClient(origin: origin, route: route, signingKey: key, http: http, connector: tracked)
    // Registration before a connection stores only the desired routing metadata.
    #expect(try await !PhoneWake.register(token: Data(repeating: 4, count: 32), environment: .sandbox, route: route, origin: origin, sockets: tracked))
    #expect(await connector.connections == 0)
    let live = try await member.connect()
    let messages = await socket.messages
    let sent = try #require(messages.first { $0.contains("wake_registration") })
    let record = try ProtocolCodec.decode(RelayWakeRegistration.self, from: Data(sent.utf8))
    #expect(record.environment == .sandbox); #expect(record.sender_device_id == "phone")
    #expect(record.apns_wake_token == Data(repeating: 4, count: 32).base64EncodedString())
    #expect(await socket.closed == false)
    #expect(await connector.connections == 1)
    await live.close()
}

@Test func reviewWakeRegistrationMustNotReplaceThePairedSocket() async throws {
    let key = Curve25519.Signing.PrivateKey(), socket = PushSocket()
    let http = SignedPhoneHTTP(key: key.publicKey), origin = URL(string: "https://synthetic.invalid")!
    let connector = PushConnector(http: http, socket: socket), route = try RelayRoute(account: "fixture", room: String(repeating: "a", count: 32), device: "phone")
    let sockets = WakeSocketConnector(base: connector)
    let member = try RelayClient(origin: origin, route: route, signingKey: key, http: http, connector: sockets)
    let live = try await member.connect()
    await connector.queue("synthetic queued ciphertext")
    for _ in 0..<3 {
        #expect(try await PhoneWake.register(token: Data(repeating: 4, count: 32), environment: .sandbox, route: route, origin: origin, sockets: sockets))
    }
    #expect(await connector.connections == 1)
    #expect(await socket.closed == false)
    #expect(await connector.queued.count == 1)
    #expect(await socket.messages.filter { $0.contains("wake_registration") }.count == 3)
    // The fake also proves a genuine second connect replaces and drains.
    let replacement = try await member.connect()
    #expect(await connector.connections == 2)
    #expect(await socket.closed)
    #expect(await connector.queued.isEmpty)
    await live.close() // Closing the old wrapper must not erase the new generation.
    #expect(try await PhoneWake.register(token: Data(repeating: 5, count: 32), environment: .production, route: route, origin: origin, sockets: sockets))
    await replacement.close()
}
