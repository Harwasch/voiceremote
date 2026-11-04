import Foundation
import Crypto
import VoiceRemoteProtocol

public struct PairedPeer: Sendable {
    public let device: DeviceInfo
    public let publicKey: Data
    public let roomID: String
    public let session: NoiseSession
}

/// Application traffic is unavailable until both trusted UI confirmations arrive.
public actor PairingConfirmation {
    public let phrase: String
    private let session: NoiseSession
    private let hash: Data
    private let publicKey: Data
    private let accountID: String
    private let roomID: String
    private var local: DeviceInfo?
    private var remote: DeviceInfo?
    private var localPending = false
    private var remotePending = false
    private var aborted = false
    private var finished = false
    init(handshake: NoiseXX, invitation: PairingInvitation) async throws {
        hash = try await handshake.handshakeHash()
        publicKey = try await handshake.remoteStaticKey()
        session = try await handshake.split()
        phrase = try VerificationPhrase.derive(handshakeHash: hash)
        accountID = invitation.payload.account_id; roomID = invitation.payload.relay_room_id
    }
    /// Invoke from a trusted local UI tap after comparing the phrase on both displays.
    public func confirmLocal(displayedPhrase: String, device: DeviceInfo, transport: any PairingTransport) async throws {
        guard !aborted, !finished, !localPending, local == nil else { throw PairingError.invalidState }
        localPending = true
        defer { localPending = false }
        do {
            guard displayedPhrase == phrase else { throw PairingError.keyMismatch }
            guard device.account_id == accountID else { throw PairingError.wrongAccount }
            let plain = Data([1]) + hash + (try ProtocolCodec.encode(device))
            let encrypted = try await session.encrypt(plain)
            try await transport.send(encrypted)
            guard !aborted else { throw PairingError.invalidState }
            local = device
        } catch { await abort(transport: transport); throw error }
    }
    public func receiveConfirmation(transport: any PairingTransport) async throws {
        guard !aborted, !finished, !remotePending, remote == nil else { throw PairingError.invalidState }
        remotePending = true
        defer { remotePending = false }
        do {
            let encrypted = try await transport.receive()
            let plain = try await session.decrypt(encrypted)
            guard plain.count > 33, plain.first == 1, Data(plain.dropFirst().prefix(32)) == hash else { throw PairingError.invalidMessage }
            let device = try ProtocolCodec.decode(DeviceInfo.self, from: Data(plain.dropFirst(33)))
            guard device.account_id == accountID else { throw PairingError.wrongAccount }
            guard !aborted else { throw PairingError.invalidState }
            remote = device
        } catch { await abort(transport: transport); throw error }
    }
    public func finish() throws -> PairedPeer {
        guard !aborted, !finished, let local, let remote else { throw PairingError.confirmationRequired }
        guard local.device_id != remote.device_id else { throw PairingError.invalidMessage }
        finished = true
        return PairedPeer(device: remote, publicKey: publicKey, roomID: roomID, session: session)
    }
    /// Persist only the result of both trusted confirmations.
    public func finish(registry: PeerRegistry) async throws -> ApplicationSession {
        guard let local else { throw PairingError.confirmationRequired }
        let paired = try finish()
        let enrollment = try await registry.enroll(paired)
        return ApplicationSession(noise: session, registry: registry, peer: enrollment, localDeviceID: local.device_id)
    }
    public func abort(transport: any PairingTransport) async {
        aborted = true
        await session.close(); await transport.close()
    }
}

public enum PairingConnection {
    /// The desktop consumes the token from message 3. Token and QR never become
    /// session credentials. Canceling or a 30-second timeout closes the transport.
    public static func initiate(invitation: PairingInvitation, staticKey: Curve25519.KeyAgreement.PrivateKey,
                                clock: any PairingClock, transport: any PairingTransport,
                                timeout: Duration = .seconds(30)) async throws -> PairingConfirmation {
        do {
            return try await withTaskCancellationHandler {
              try await withThrowingTaskGroup(of: PairingConfirmation.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    try invitation.validate(clock: clock)
                    let handshake = NoiseXX(role: .initiator, staticKey: staticKey, prologue: invitation.prologue)
                    try await transport.send(handshake.writeMessage())
                    let response = try await transport.receive()
                    let payload = try await handshake.readMessage(response)
                    guard payload.isEmpty else { throw PairingError.invalidMessage }
                    guard try await handshake.remoteStaticKey() == invitation.desktopKey else { throw PairingError.keyMismatch }
                    try Task.checkCancellation()
                    try invitation.validate(clock: clock)
                    try await transport.send(handshake.writeMessage(payload: invitation.token))
                    try Task.checkCancellation()
                    return try await PairingConfirmation(handshake: handshake, invitation: invitation)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await transport.close()
                    throw PairingError.expiredQR
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw PairingError.invalidState }
                return result
              }
            } onCancel: {
                Task { await transport.close() }
            }
        } catch { await transport.close(); throw error }
    }
}

public extension PairedPeer {
    /// Hosts may validate/narrow UI enrollment before publishing the session.
    /// PairedPeer can only be obtained after both phrase confirmations.
    func applicationSession(registry: PeerRegistry, localDeviceID: String) async throws -> ApplicationSession {
        let enrollment = try await registry.enroll(self)
        return ApplicationSession(noise: session, registry: registry, peer: enrollment, localDeviceID: localDeviceID)
    }
}
