import Foundation
import Crypto
import VoiceRemoteProtocol

enum SessionWire {
    static let packetBytes = 11_000
    static let chunkBytes = 10_975
    static let innerBytes = 2 * 1024 * 1024
    static func u32(_ n: Int) -> Data { Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    static func number(_ bytes: Data) -> Int { bytes.reduce(0) { ($0 << 8) | Int($1) } }
    static func resumePrologue(account: String, room: String) -> Data {
        var bytes = Data("voiceremote/session/v1\0".utf8)
        for value in [account, room] { let v = Data(value.utf8); bytes += u32(v.count) + v }
        return bytes
    }
    static func checkAccounts(_ bytes: Data, account: String) throws {
        func check(_ value: Any) throws {
            if let fields = value as? [String: Any] {
                if let id = fields["account_id"] { guard id as? String == account else { throw PairingError.wrongAccount } }
                for v in fields.values { try check(v) }
            } else if let values = value as? [Any] { for v in values { try check(v) } }
        }
        try check(JSONSerialization.jsonObject(with: bytes))
    }
}

/// All adapters must unblock on close/cancellation. The deadline covers the
/// entire operation, including every fragment, rather than restarting per packet.
func withTransportDeadline<T: Sendable>(_ transport: any PairingTransport, timeout: Duration,
    operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await transport.close()
                throw PairingError.closedTransport
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw PairingError.invalidState }
            return value
        }
    } onCancel: { Task { await transport.close() } }
}

/// Ordered application boundary, shared by LAN and relay. No action executor.
/// Callers serialize path switches; transport failure requires fresh resume XX.
public actor ApplicationSession {
    public let peer: Enrollment
    private let registry: PeerRegistry
    private let noise: NoiseSession
    private let localDeviceID: String
    private var closed = false
    private var sending = false
    private var receiving = false
    init(noise: NoiseSession, registry: PeerRegistry, peer: Enrollment, localDeviceID: String) {
        self.noise = noise; self.registry = registry; self.peer = peer; self.localDeviceID = localDeviceID
    }
    private func checkActive() async throws {
        guard !closed else { throw PairingError.invalidState }
        try await registry.require(peer)
        guard !closed else { throw PairingError.invalidState }
    }
    public func close(transport: any PairingTransport) async {
        closed = true; await noise.close(); await transport.close()
    }
    public func send(_ message: InnerMessage, transport: any PairingTransport) async throws {
        guard !sending else { throw PairingError.invalidState }
        sending = true; defer { sending = false }
        do {
            try await checkActive()
            let bytes = try ProtocolCodec.encode(message)
            try SessionWire.checkAccounts(bytes, account: peer.device.account_id)
            guard bytes.count <= SessionWire.innerBytes else { throw PairingError.messageTooLarge }
            if case .revoke(let revoke) = message {
                guard revoke.device_id == peer.device.device_id else { throw PairingError.invalidMessage }
            }
            if bytes.count + 16 <= SessionWire.packetBytes {
                try await write(bytes, transport: transport)
            } else {
                for offset in stride(from: 0, to: bytes.count, by: SessionWire.chunkBytes) {
                    let chunk = bytes.subdata(in: offset..<min(offset + SessionWire.chunkBytes, bytes.count))
                    try await write(Data([3]) + SessionWire.u32(bytes.count) + SessionWire.u32(offset) + chunk, transport: transport)
                }
            }
            if case .revoke = message {
                try await registry.revoke(peer)
                await close(transport: transport)
            }
        } catch { await close(transport: transport); throw error }
    }
    private func write(_ bytes: Data, transport: any PairingTransport) async throws {
        try await checkActive()
        await transport.retainedSession()
        let packet = try await noise.encrypt(bytes)
        try await checkActive()
        try await withTransportDeadline(transport, timeout: .seconds(10)) { try await transport.send(packet) }
        try await checkActive()
    }
    public func receive(transport: any PairingTransport, timeout: Duration = .seconds(90)) async throws -> InnerMessage {
        guard !receiving else { throw PairingError.invalidState }
        receiving = true; defer { receiving = false }
        do {
            let result = try await withTransportDeadline(transport, timeout: timeout) { try await self.read(transport: transport) }
            try await checkActive()
            // Receiving revoke closes every session for this enrollment. It is
            // metadata returned to trusted policy, never a model dispatch path.
            if case .revoke(let revoke) = result {
                guard revoke.device_id == localDeviceID else { throw PairingError.invalidMessage }
                try await registry.revoke(peer)
                await close(transport: transport)
            }
            return result
        } catch { await close(transport: transport); throw error }
    }
    private func read(transport: any PairingTransport) async throws -> InnerMessage {
        var assembled = Data(); var total: Int?
        while true {
            try Task.checkCancellation()
            try await checkActive()
            await transport.retainedSession()
            let packet = try await transport.receive()
            try await checkActive()
            guard !packet.isEmpty, packet.count <= SessionWire.packetBytes else { throw PairingError.messageTooLarge }
            let plain = try await noise.decrypt(packet)
            guard !plain.isEmpty else { throw PairingError.invalidMessage }
            if plain.first == 3 {
                guard plain.count > 9 else { throw PairingError.invalidMessage }
                let nextTotal = SessionWire.number(plain.subdata(in: 1..<5))
                let offset = SessionWire.number(plain.subdata(in: 5..<9))
                guard nextTotal > 0, nextTotal <= SessionWire.innerBytes, offset == assembled.count,
                      total == nil || total == nextTotal, plain.count - 9 <= nextTotal - assembled.count else { throw PairingError.invalidMessage }
                total = nextTotal; assembled += plain.dropFirst(9)
                if assembled.count < nextTotal { continue }
            } else {
                guard total == nil else { throw PairingError.invalidMessage }
                assembled = plain
            }
            let message = try ProtocolCodec.decode(InnerMessage.self, from: assembled)
            try SessionWire.checkAccounts(assembled, account: peer.device.account_id)
            try await checkActive()
            return message
        }
    }
}

public enum SessionResume {
    /// Fresh XX, existing enrollment only. Responder's 02||hash ready consumes
    /// receive nonce zero; the initiator's first application packet uses zero.
    public static func initiate(staticKey: Curve25519.KeyAgreement.PrivateKey, registry: PeerRegistry,
        peer: Enrollment, localDeviceID: String, transport: any PairingTransport,
        timeout: Duration = .seconds(30)) async throws -> ApplicationSession {
        do {
            return try await withTransportDeadline(transport, timeout: timeout) {
                try await registry.require(peer)
                let state = NoiseXX(role: .initiator, staticKey: staticKey,
                    prologue: SessionWire.resumePrologue(account: peer.device.account_id, room: peer.roomID))
                try await transport.send(state.writeMessage())
                let payload = try await state.readMessage(transport.receive())
                guard payload.isEmpty, try await state.remoteStaticKey() == peer.publicKey else { throw PairingError.keyMismatch }
                try await registry.require(peer)
                try await transport.send(state.writeMessage())
                let hash = try await state.handshakeHash()
                let noise = try await state.split()
                do {
                    let ready = try await noise.decrypt(transport.receive())
                    guard ready == Data([2]) + hash else { throw PairingError.invalidMessage }
                    try await registry.require(peer)
                    return ApplicationSession(noise: noise, registry: registry, peer: peer, localDeviceID: localDeviceID)
                } catch { await noise.close(); throw error }
            }
        } catch { await transport.close(); throw error }
    }
}
