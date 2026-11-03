import Foundation
import Crypto
import VoiceRemoteProtocol

public struct RelayRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data
    public init(url: URL, method: String, headers: [String: String] = [:], body: Data = Data()) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}
public enum RelayError: Error, Equatable, Sendable {
    case httpRefused(Int)
    public var permanent: Bool {
        if case .httpRefused(let status) = self { return (400..<500).contains(status) && status != 408 && status != 429 }
        return false
    }
}
public struct RelayResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}
/// Implementations enforce a 4096-byte response cap, a two-second deadline,
/// HTTPS and no redirects. Fakes use exactly the same signed request boundary.
public protocol RelayHTTP: Sendable { func perform(_ request: RelayRequest) async throws -> RelayResponse }
public enum WebSocketMessage: Sendable { case text(String), binary(Data), closed }
/// ping returns only after the matching pong. close/cancellation unblock I/O.
public protocol WebSocket: Sendable {
    func send(text: String) async throws
    func receive() async throws -> WebSocketMessage
    func ping() async throws
    func close() async
}
public struct WebSocketUpgrade: Sendable {
    public let socket: any WebSocket
    public let headers: [String: String]
    public init(socket: any WebSocket, headers: [String: String]) { self.socket = socket; self.headers = headers }
}
public protocol WebSocketConnector: Sendable {
    func connect(_ request: RelayRequest) async throws -> WebSocketUpgrade
}
public protocol RelaySleeper: Sendable { func sleep(for duration: Duration) async throws }
public struct TaskRelaySleeper: RelaySleeper {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
public struct RelayRoute: Sendable {
    public let account: String
    public let room: String
    public let device: String
    public init(account: String, room: String, device: String) throws {
        for value in [account, room, device] { try Self.validateID(value) }
        guard room.utf8.count == 32, room.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PairingError.invalidQR }
        self.account = account; self.room = room; self.device = device
    }
    static func validateID(_ value: String) throws {
        guard (1...128).contains(value.utf8.count), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw PairingError.invalidMessage }
    }
}

// Sidecar responses are closed flat objects. Parse before JSONDecoder can erase
// duplicate keys or normalize exponent/fraction timestamp tokens.
enum RelayJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func array(_ values: [String], integer: Int64? = nil) throws -> Data {
        var strings = try values.map { String(decoding: try encode($0), as: UTF8.self) }
        if let integer { strings.append(String(integer)) }
        return Data(("[" + strings.joined(separator: ",") + "]").utf8)
    }
    static func flat(_ data: Data, fields: Set<String>) throws -> [String: Data] {
        guard data.count <= 4096, String(data: data, encoding: .utf8) != nil else { throw PairingError.invalidMessage }
        let bytes = Array(data); var i = 0
        func space() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        func take(_ b: UInt8) throws { space(); guard i < bytes.count, bytes[i] == b else { throw PairingError.invalidMessage }; i += 1 }
        func string() throws -> Data {
            let start = i; guard i < bytes.count, bytes[i] == 34 else { throw PairingError.invalidMessage }; i += 1
            while i < bytes.count {
                let b = bytes[i]; i += 1
                if b == 34 {
                    let raw = Data(bytes[start..<i]); let s = try JSONDecoder().decode(String.self, from: raw)
                    guard s.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw PairingError.invalidMessage }
                    return raw
                }
                if b == 92 { guard i < bytes.count else { throw PairingError.invalidMessage }; i += 1 }
            }
            throw PairingError.invalidMessage
        }
        try take(123); space(); var result: [String: Data] = [:]
        while i < bytes.count && bytes[i] != 125 {
            let key = try JSONDecoder().decode(String.self, from: string())
            guard fields.contains(key), result[key] == nil else { throw PairingError.invalidMessage }
            try take(58); space()
            let value: Data
            if i < bytes.count && bytes[i] == 34 { value = try string() }
            else {
                let start = i
                while i < bytes.count && ![9, 10, 13, 32, 44, 125].contains(bytes[i]) { i += 1 }
                value = Data(bytes[start..<i])
                let text = String(decoding: value, as: UTF8.self)
                guard text == "true" || text == "false" ||
                    (!text.isEmpty && text.utf8.allSatisfy({ (48...57).contains($0) }) && (text == "0" || text.first != "0") && Int64(text).map({ $0 <= 9_007_199_254_740_991 }) == true) else { throw PairingError.invalidMessage }
            }
            result[key] = value; space()
            if i < bytes.count && bytes[i] == 44 { i += 1; space(); guard i < bytes.count && bytes[i] != 125 else { throw PairingError.invalidMessage } }
            else { break }
        }
        try take(125); space()
        guard i == bytes.count, Set(result.keys) == fields else { throw PairingError.invalidMessage }
        return result
    }
    static func value<T: Decodable>(_ type: T.Type, _ fields: [String: Data], _ key: String) throws -> T {
        guard let raw = fields[key] else { throw PairingError.invalidMessage }
        return try JSONDecoder().decode(type, from: raw)
    }
    static func digest(_ bytes: Data) -> String { Data(SHA256.hash(data: bytes)).base64EncodedString() }
}

public struct RelayClient: Sendable {
    public let route: RelayRoute
    private let base: URL
    private let identity: Curve25519.Signing.PrivateKey
    private let http: any RelayHTTP
    private let connector: any WebSocketConnector
    private let clock: any PairingClock
    public init(origin: URL, route: RelayRoute, signingKey: Curve25519.Signing.PrivateKey,
                http: any RelayHTTP, connector: any WebSocketConnector, clock: any PairingClock = SystemPairingClock(), allowLoopback: Bool = false) throws {
        let loopback = allowLoopback && origin.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(origin.host ?? "")
        guard (origin.scheme == "https" || loopback), origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { throw PairingError.invalidQR }
        self.base = origin.appendingPathComponent("v1/accounts/\(route.account)/rooms/\(route.room)")
        self.route = route; identity = signingKey; self.http = http; self.connector = connector; self.clock = clock
    }
    private func sign(_ bytes: Data) throws -> String { try identity.signature(for: bytes).base64EncodedString() }
    private func post(_ operation: String, body: Data, headers: [String: String] = [:]) async throws -> Data {
        guard body.count <= 4096 else { throw PairingError.messageTooLarge }
        let response = try await http.perform(.init(url: base.appendingPathComponent(operation), method: "POST",
            headers: headers.merging(["Content-Type": "application/json"]) { _, v in v }, body: body))
        guard (200...299).contains(response.status) else { throw RelayError.httpRefused(response.status) }
        guard response.body.count <= 4096 else { throw PairingError.invalidMessage }
        return response.body
    }
    /// The desktop registers only the hash/expiry. Phone supplies its own fresh
    /// per-room Ed25519 key at redemption; never reuse the QR's Noise key.
    public func redeem(_ invitation: PairingInvitation) async throws {
        try invitation.validate(clock: clock)
        guard invitation.payload.account_id == route.account, invitation.payload.relay_room_id == route.room else { throw PairingError.wrongAccount }
        let key = identity.publicKey.rawRepresentation.base64EncodedString()
        let p = invitation.payload
        let proof = try RelayJSON.array(["voiceremote-relay-join-v1", route.account, route.room, route.device, key, p.one_use_token], integer: p.expires_at)
        struct Join: Encodable { let device_id: String; let public_key: String; let one_use_token: String; let expires_at: Int64; let signature: String }
        let body = try RelayJSON.encode(Join(device_id: route.device, public_key: key, one_use_token: p.one_use_token, expires_at: p.expires_at, signature: sign(proof)))
        do {
            let fields = try RelayJSON.flat(await post("join", body: body), fields: ["joined"])
            guard try RelayJSON.value(Bool.self, fields, "joined") else { throw PairingError.invalidMessage }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A lost successful response consumes the token. A fresh signed
            // member connect proves the retained identity already joined. No
            // invite replay, changed key or new QR is needed while QR is live.
            let original = error
            do {
                let recovered = try await connect()
                await recovered.close()
            } catch { throw original }
        }
    }
    private func authorization(operation: String, body: Data) async throws -> [String: String] {
        let hash = RelayJSON.digest(body)
        let request = try RelayJSON.encode(["device_id": route.device, "operation": operation, "body_sha256": hash])
        let proof = try RelayJSON.array(["voiceremote-relay-challenge-v1", route.account, route.room, RelayJSON.digest(request)])
        let started = ContinuousClock.now
        let response = try await post("challenge", body: request, headers: ["X-Relay-Signature": sign(proof)])
        let fields = try RelayJSON.flat(response, fields: ["challenge", "message", "expires_at", "server_time"])
        let challenge = try RelayJSON.value(String.self, fields, "challenge")
        guard let nonce = Data(base64Encoded: challenge), nonce.count == 32, nonce.base64EncodedString() == challenge else { throw PairingError.invalidMessage }
        let expires = try RelayJSON.value(Int64.self, fields, "expires_at")
        let serverTime = try RelayJSON.value(Int64.self, fields, "server_time")
        guard serverTime >= 0, expires > serverTime, expires - serverTime <= 60_000,
              started.duration(to: .now) < .milliseconds(expires - serverTime) else { throw PairingError.expiredQR }
        let expected = try RelayJSON.array(["voiceremote-relay-auth-v1", route.account, route.room, route.device, operation, hash, challenge], integer: expires)
        guard try RelayJSON.value(String.self, fields, "message") == String(decoding: expected, as: UTF8.self) else { throw PairingError.invalidMessage }
        return ["X-Relay-Challenge": challenge, "X-Relay-Signature": try sign(expected)]
    }
    public func revoke(device: String) async throws {
        try RelayRoute.validateID(device)
        let body = try RelayJSON.encode(["device_id": device])
        _ = try await post("revoke", body: body, headers: authorization(operation: "revoke", body: body))
    }
    public func connect() async throws -> RelayTransport {
        let headers = try await authorization(operation: "connect", body: Data())
        var components = URLComponents(url: base.appendingPathComponent("connect"), resolvingAgainstBaseURL: false)!
        components.scheme = base.scheme == "http" ? "ws" : "wss"
        let upgrade = try await connector.connect(.init(url: components.url!, method: "GET", headers: headers))
        do {
            try Task.checkCancellation()
            let raw = upgrade.headers.first { $0.key.lowercased() == "x-relay-dropped-frames" }?.value ?? "0"
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let dropped = UInt64(raw) else { throw PairingError.invalidMessage }
            let transport = RelayTransport(socket: upgrade.socket, route: route, droppedFrames: dropped)
            try await transport.start()
            return transport
        } catch { await upgrade.socket.close(); throw error }
    }
    /// A reconnect returns a new transport. The caller performs session/v1 XX;
    /// failed application writes are never retried or replayed here.
    public func reconnect(registry: PeerRegistry? = nil, peer: Enrollment? = nil, sleeper: any RelaySleeper = TaskRelaySleeper()) async throws -> RelayTransport {
        var delay: Duration = .milliseconds(500)
        while true {
            try Task.checkCancellation()
            do { return try await connect() }
            catch is CancellationError { throw CancellationError() }
            catch let refusal as RelayError where refusal.permanent {
                if refusal == .httpRefused(403), let registry, let peer { try await registry.revoke(peer) }
                throw refusal
            }
            catch { try await sleeper.sleep(for: delay); delay = min(delay * 2, .seconds(30)) }
        }
    }
}

public actor RelayTransport: PairingTransport {
    public let droppedFrames: UInt64
    private let socket: any WebSocket
    private let route: RelayRoute
    private var closed = false
    private var receiving = false
    private var sending = false
    private var lastReceived = ContinuousClock.now
    private var heartbeat: Task<Void, Never>?
    private var peerSender: String?
    private var lastSender: String?
    private var records: RelayRecords
    init(socket: any WebSocket, route: RelayRoute, droppedFrames: UInt64, records: RelayRecords = RelayRecords()) {
        self.records = records
        self.socket = socket; self.route = route; self.droppedFrames = droppedFrames
    }
    func start() async throws {
        let presence = RelayPresence(account_id: route.account, room_id: route.room, sender_device_id: route.device, state: .online)
        try await socket.send(text: String(decoding: ProtocolCodec.encode(presence), as: UTF8.self))
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)); guard let self else { return }; try await self.keepalive() }
                catch { await self?.close(); return }
            }
        }
    }
    // Ping itself is bounded: a silent peer cannot leave a pending pong forever.
    func keepalive(timeout: Duration = .seconds(20)) async throws {
        guard !closed, lastReceived.duration(to: .now) < .seconds(30) else { throw PairingError.closedTransport }
        try await withTransportDeadline(self, timeout: timeout) { try await self.socket.ping() }
        lastReceived = .now
    }
    public func retainedSession() { records.retained = true }
    public func send(_ frame: Data) async throws {
        guard !sending else { throw PairingError.invalidState }
        sending = true; defer { sending = false }
        do {
            guard !closed, !frame.isEmpty, frame.count <= SessionWire.packetBytes else { throw PairingError.messageTooLarge }
            if records.step == 0, records.retained {
                let epoch = records.local + Data(repeating: 0, count: 32)
                try await rawSend(RelayRecords.encode(6, epoch: epoch, payload: frame))
                records.epoch = epoch; records.step = 3
                return
            }
            if records.step == 0 {
                guard frame.count == 32, !receiving else { throw PairingError.invalidState }
                try await rawSend(RelayRecords.encode(0, epoch: records.local))
                // Only an ack echoing this *fresh* initiator socket nonce may
                // choose the responder generation. Old queued acks are ignored.
                while records.epoch == nil {
                    let raw = try await rawReceive()
                    if let (kind, body) = RelayRecords.decode(raw), kind == 1,
                       body.count == 64, body.prefix(32) == records.local { records.epoch = body; peerSender = lastSender }
                }
            }
            guard let epoch = records.epoch else { throw PairingError.invalidState }
            let kind: UInt8 = records.step == 0 ? 2 : records.step == 1 ? 3 : records.step == 2 ? 4 : 5
            try await rawSend(RelayRecords.encode(kind, epoch: epoch, payload: frame))
            records.step = min(3, records.step + 1)
        } catch { await close(); throw error }
    }
    private func rawSend(_ frame: Data) async throws {
        guard !closed, frame.count <= SessionWire.packetBytes + 69 else { throw PairingError.messageTooLarge }
        let encoded = try ProtocolCodec.encode(RelayCiphertext(account_id: route.account, room_id: route.room,
            sender_device_id: route.device, ciphertext: frame.base64EncodedString()))
        guard encoded.count <= 16_384 else { throw PairingError.messageTooLarge }
        try await socket.send(text: String(decoding: encoded, as: UTF8.self))
        guard !closed else { throw PairingError.closedTransport }
    }
    public func receive() async throws -> Data {
        guard !closed, !receiving, !sending || records.step == 3 else { throw PairingError.invalidState }
        receiving = true; defer { receiving = false }
        do {
            while true {
                let raw = try await rawReceive()
                guard let (kind, body) = RelayRecords.decode(raw) else { continue }
                if records.step == 0, records.retained, kind == 6, body.count > 64,
                   body.subdata(in: 32..<64) == Data(repeating: 0, count: 32) {
                    records.epoch = Data(body.prefix(64)); peerSender = lastSender; records.step = 3
                    return Data(body.dropFirst(64))
                }
                if records.step == 0 {
                    if kind == 0, body.count == 32 {
                        try await rawSend(RelayRecords.encode(1, epoch: body + records.local))
                        continue
                    }
                    guard kind == 2, body.count == 64 + 32, body.subdata(in: 32..<64) == records.local else { continue }
                    records.epoch = Data(body.prefix(64)); peerSender = lastSender
                }
                guard let epoch = records.epoch, body.count > 64, body.prefix(64) == epoch else { continue }
                let expected: UInt8 = records.step == 0 ? 2 : records.step == 1 ? 3 : records.step == 2 ? 4 : 5
                guard kind == expected else { throw PairingError.invalidMessage }
                let packet = Data(body.dropFirst(64))
                guard packet.count <= SessionWire.packetBytes else { throw PairingError.messageTooLarge }
                records.step = min(3, records.step + 1)
                return packet
            }
        } catch { await close(); throw error }
    }
    private func rawReceive() async throws -> Data {
        do {
            while true {
                let message = try await socket.receive()
                guard !closed, case .text(let text) = message, text.utf8.count <= 16_384 else { throw PairingError.invalidMessage }
                lastReceived = .now
                switch try ProtocolCodec.decode(RelayFrame.self, from: Data(text.utf8)) {
                case .relayCiphertext(let frame):
                    try RelayRoute.validateID(frame.sender_device_id)
                    guard frame.account_id == route.account, frame.room_id == route.room, frame.sender_device_id != route.device,
                        let bytes = Data(base64Encoded: frame.ciphertext), !bytes.isEmpty, bytes.count <= SessionWire.packetBytes + 69,
                        bytes.base64EncodedString() == frame.ciphertext else { throw PairingError.invalidMessage }
                    lastSender = frame.sender_device_id
                    return bytes
                case .relayPresence(let frame):
                    try RelayRoute.validateID(frame.sender_device_id)
                    guard frame.account_id == route.account, frame.room_id == route.room else { throw PairingError.wrongAccount }
                    if frame.state == .offline, frame.sender_device_id == peerSender { throw PairingError.closedTransport }
                default: throw PairingError.invalidMessage
                }
            }
        } catch { await close(); throw error }
    }
    public func close() async {
        closed = true; heartbeat?.cancel(); heartbeat = nil; await socket.close()
    }
}
