// Purpose: content-free push registration and strict wake-hint validation.
// Inputs: relay-join and audit-archive contracts; portable fixtures verify bytes.
import Foundation
import Pairing
import VoiceRemoteProtocol

public enum PhoneWake {
    /// Accept precisely the fixed APNs signal. Never decode content as work.
    public static func isHint(_ bytes: Data) -> Bool {
        guard bytes.count <= 128,
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(value.keys) == ["aps"], let aps = value["aps"] as? [String: Any],
              Set(aps.keys) == ["content-available"], let n = aps["content-available"] as? NSNumber,
              String(cString: n.objCType) != "c", n.intValue == 1, n.doubleValue == 1 else { return false }
        return true
    }
    /// Routing metadata travels on the already authenticated device socket.
    /// Registration never opens /connect, consumes queued frames, or closes a peer.
    @discardableResult public static func register(token: Data, environment: RelayWakeRegistrationEnvironment,
        route: RelayRoute, origin: URL, sockets: WakeSocketConnector) async throws -> Bool {
        guard (1...256).contains(token.count), origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else { throw PairingError.invalidMessage }
        let body = try ProtocolCodec.encode(RelayWakeRegistration(account_id: route.account,
            room_id: route.room, sender_device_id: route.device,
            apns_wake_token: token.base64EncodedString(), environment: environment))
        var parts = URLComponents(url: origin.appendingPathComponent("v1/accounts/\(route.account)/rooms/\(route.room)/connect"), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        return try await sockets.register(body, at: parts.url!)
    }
}

/// A connector adapter exposes only control writes on its actual live sockets.
/// Desired tokens survive a transport reconnect; application reads stay exclusively
/// with RelayTransport. A closed old generation cannot erase its replacement.
public actor WakeSocketConnector: WebSocketConnector {
    private let base: any WebSocketConnector
    private struct Live { let id: UUID; let socket: any WebSocket }
    private var live: [URL: Live] = [:]
    private var desired: [URL: Data] = [:]
    public init(base: any WebSocketConnector) { self.base = base }
    public func connect(_ request: RelayRequest) async throws -> WebSocketUpgrade {
        let opened = try await base.connect(request), id = UUID()
        live[request.url] = Live(id: id, socket: opened.socket)
        do {
            if let bytes = desired[request.url] { try await opened.socket.send(text: String(decoding: bytes, as: UTF8.self)) }
            return WebSocketUpgrade(socket: WakeTrackedSocket(base: opened.socket, owner: self, url: request.url, id: id), headers: opened.headers)
        } catch { remove(request.url, id: id); await opened.socket.close(); throw error }
    }
    func register(_ bytes: Data, at url: URL) async throws -> Bool {
        desired[url] = bytes
        guard let current = live[url] else { return false }
        try await current.socket.send(text: String(decoding: bytes, as: UTF8.self))
        // An acknowledgement is not in this protocol. Report submission only.
        return live[url]?.id == current.id
    }
    func remove(_ url: URL, id: UUID) { if live[url]?.id == id { live.removeValue(forKey: url) } }
    public func forget(origin: URL, route: RelayRoute) async {
        var parts = URLComponents(url: origin.appendingPathComponent("v1/accounts/\(route.account)/rooms/\(route.room)/connect"), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        if let url = parts.url { desired.removeValue(forKey: url) }
    }
}
private struct WakeTrackedSocket: WebSocket {
    let base: any WebSocket
    let owner: WakeSocketConnector
    let url: URL
    let id: UUID
    func send(text: String) async throws { try await base.send(text: text) }
    func ping() async throws { try await base.ping() }
    func receive() async throws -> WebSocketMessage {
        do {
            let value = try await base.receive()
            if case .closed = value { await owner.remove(url, id: id) }
            return value
        } catch { await owner.remove(url, id: id); throw error }
    }
    func close() async { await owner.remove(url, id: id); await base.close() }
}
