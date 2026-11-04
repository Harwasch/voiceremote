import Foundation
import Crypto
import Pairing

/// Mirrors desktop resume_initiate (session/v1): no enrollment token, no persisted
/// nonces, pinned remote static key, fresh handshake and encrypted 02 || hash ready.
public enum PeerResume {
    public static func prologue(accountID: String, roomID: String) -> Data {
        var bytes = Data("voiceremote/session/v1\0".utf8)
        for string in [accountID, roomID] {
            let data = Data(string.utf8), length = UInt32(string.utf8.count)
            bytes.append(contentsOf: (0..<4).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
            bytes.append(data)
        }
        return bytes
    }
    public static func initiate(accountID: String, roomID: String, localPrivateKey: Data, expectedRemoteKey: Data,
                                transport: any PairingTransport, timeout: Duration = .seconds(30)) async throws -> NoiseSession {
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: NoiseSession.self) { group in
                    group.addTask {
                        try Task.checkCancellation()
                        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localPrivateKey)
                        let handshake = NoiseXX(role: .initiator, staticKey: key, prologue: prologue(accountID: accountID, roomID: roomID))
                        try await transport.send(handshake.writeMessage())
                        let payload = try await handshake.readMessage(transport.receive())
                        guard payload.isEmpty, try await handshake.remoteStaticKey() == expectedRemoteKey else { throw PairingError.keyMismatch }
                        try await transport.send(handshake.writeMessage())
                        let hash = try await handshake.handshakeHash()
                        let session = try await handshake.split()
                        let ready = try await session.decrypt(transport.receive())
                        guard ready == Data([2]) + hash else { await session.close(); throw PairingError.invalidMessage }
                        try Task.checkCancellation()
                        return session
                    }
                    group.addTask { try await Task.sleep(for: timeout); await transport.close(); throw PairingError.closedTransport }
                    defer { group.cancelAll() }
                    guard let session = try await group.next() else { throw PairingError.closedTransport }
                    return session
                }
            } onCancel: { Task { await transport.close() } }
        } catch { await transport.close(); throw error }
    }
}
