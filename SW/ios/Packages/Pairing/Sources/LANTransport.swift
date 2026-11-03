import Foundation

/// Reliable TCP byte stream. read(upTo:) returns nonempty bytes or throws at EOF;
/// write sends all bytes. Implementations unblock reads/writes on close/cancel.
public protocol LANByteStream: Sendable {
    func read(upTo count: Int) async throws -> Data
    func write(_ bytes: Data) async throws
    func close() async
}

enum LANAddress {
    static func allowed(_ data: Data) -> Bool {
        let b = Array(data)
        if b.count == 4 {
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        guard b.count == 16 else { return false }
        if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 255, b[11] == 255 { return allowed(Data(b.suffix(4))) }
        return (b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1) ||
            (b[0] & 0xfe == 0xfc) || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)
    }
}

/// Same PairingTransport boundary as the relay; u32-BE length then Noise packet.
public actor LANTransport: PairingTransport {
    private let stream: any LANByteStream
    private var closed = false
    private var sending = false
    private var receiving = false
    public init(stream: any LANByteStream) { self.stream = stream }
    public func send(_ frame: Data) async throws {
        guard !sending else { throw PairingError.invalidState }
        sending = true; defer { sending = false }
        do {
            guard !closed, !frame.isEmpty, frame.count <= 65_535 else { throw PairingError.messageTooLarge }
            try await stream.write(SessionWire.u32(frame.count) + frame)
            guard !closed else { throw PairingError.closedTransport }
        } catch { await close(); throw error }
    }
    private func exact(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            guard !closed else { throw PairingError.closedTransport }
            let part = try await stream.read(upTo: count - bytes.count)
            guard !part.isEmpty, part.count <= count - bytes.count else { throw PairingError.closedTransport }
            bytes += part
        }
        return bytes
    }
    public func receive() async throws -> Data {
        guard !receiving else { throw PairingError.invalidState }
        receiving = true; defer { receiving = false }
        do {
            let length = try SessionWire.number(await exact(4))
            guard (1...65_535).contains(length) else { throw PairingError.messageTooLarge }
            return try await exact(length)
        } catch { await close(); throw error }
    }
    public func close() async { closed = true; await stream.close() }
}

#if canImport(Network)
import Network

/// Thin iPhone TCP adapter. Discovery supplies a private/LAN endpoint; there is
/// no public listener or automatic WAN fallback. TCP keepalive is 10s/5s.
public final class NetworkLANStream: LANByteStream, @unchecked Sendable {
    private let connection: NWConnection
    public init(host: NWEndpoint.Host, port: NWEndpoint.Port) throws {
        let allowed: Bool
        switch host {
        case .ipv4(let address): allowed = LANAddress.allowed(address.rawValue)
        case .ipv6(let address): allowed = LANAddress.allowed(address.rawValue)
        default: allowed = false
        }
        guard allowed else { throw PairingError.invalidMessage }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5
        connection = NWConnection(host: host, port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection.start(queue: DispatchQueue(label: "voiceremote.lan"))
    }
    public func read(upTo count: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count) { bytes, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: PairingError.closedTransport) }
                }
            }
        } onCancel: { self.connection.cancel() }
    }
    public func write(_ bytes: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { self.connection.cancel() }
    }
    public func close() async { connection.cancel() }
}
#endif
