import Foundation
import VoiceRemoteProtocol

/// Removal remains local and durable even if the desktop is offline. Cleanup is
/// always attempted; callers display notification failure instead of claiming it sent.
public enum PeerRevocationError: Error { case notification, localCleanup }
@MainActor public enum PeerRevocation {
    public static func perform(deviceID: String, accountID: String, store: PeerStore,
                               send: (Data) async throws -> Void, erase: () throws -> Void,
                               close: () async -> Void, now: Int64) async throws {
        var failure: PeerRevocationError?
        do { try store.markRevoked(deviceID: deviceID, notificationPending: true) } catch { failure = .localCleanup }
        let command = UUID().uuidString
        do {
            let revoke = Revoke(account_id: accountID, device_id: deviceID, command_id: command,
                idempotency_key: command, revoked_at: now)
            try await send(ProtocolCodec.encode(revoke))
            try store.markRevoked(deviceID: deviceID, notificationPending: false)
        } catch { if failure == nil { failure = .notification } }
        do { try erase() } catch { failure = .localCleanup }
        await close()
        if let failure { throw failure }
    }
}
