// Purpose: phone AEAD, signed archive transport and recovery adapters.
// Inputs: audit-archive v2; verified by portable synthetic tests, devices unverified.
import Foundation
import Crypto
import Policy
import Pairing
import TrustedInput
import VoiceRemoteProtocol

public enum AuditCheckpointBootstrap {
    /// Old builds could create an empty journal without ever saving a checkpoint.
    /// Only that empty legacy slot can migrate. Missing anchored/nonempty history
    /// is loss, never a basis for reconstructing a trusted head from disk.
    public static func initial(markerExists: Bool, journal: Data?, pendingExists: Bool, legacySlot: Bool) throws -> AuditCheckpoint {
        guard !markerExists, !pendingExists, journal == nil || (legacySlot && journal!.isEmpty) else { throw PolicyError.auditUnavailable }
        return .empty
    }
}

@MainActor public final class PhoneArchiveCipher: AuditArchiveCipher {
    private let key: SymmetricKey
    public init(key: Data) throws {
        guard key.count == 32 else { throw PolicyError.auditUnavailable }
        self.key = SymmetricKey(data: key)
    }
    public func seal(_ plaintext: Data, context: Data) throws -> Data {
        guard let bytes = try AES.GCM.seal(plaintext, using: key, authenticating: context).combined else {
            throw PolicyError.auditUnavailable
        }
        return bytes
    }
    public func open(_ ciphertext: Data, context: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: context)
    }
}

@MainActor public enum PhoneArchiveMaintenance {
    public static func status(roomCount: Int, messages: [String]) -> String {
        roomCount == 0 ? "No relay audit copy is available. Pair a relay-backed computer to enable it." : messages.joined(separator: "\n")
    }
    public static func replicate(log: AuditLog, client: any AuditArchiveClient, cipher: any AuditArchiveCipher,
        store: any AuditArchiveAnchorStore, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> AuditArchiveAnchor {
        let before = try store.loadArchive().anchor
        let anchor = try await AuditArchive.replicate(log: log, client: client, cipher: cipher, store: store, now: now)
        // A prior scheduled check of an empty archive must not suppress the
        // required first real upload read-back within the same 24-hour window.
        if before.count == 0, anchor.count > 0 {
            try await AuditArchive.verifyScheduled(client: client, cipher: cipher, store: store, now: now, force: true)
        }
        return anchor
    }
}

/// HTTP implementation must bound reads to 2,100,000 bytes and two seconds,
/// disable redirects/cookies/cache and avoid logging request/response bodies.
@MainActor public final class PhoneArchiveClient: AuditArchiveClient {
    private let member: RelayClient
    private let base: URL
    private let http: any RelayHTTP
    public init(member: RelayClient, origin: URL, http: any RelayHTTP) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { throw PolicyError.invalid }
        self.member = member; self.http = http
        base = origin.appendingPathComponent("v1/accounts/\(member.route.account)/rooms/\(member.route.room)")
    }
    private func request(_ operation: String, bytes: Data, limit: Int) async throws -> Data {
        guard bytes.count <= limit else { throw PolicyError.invalid }
        let proof = try await member.authorization(operation: operation, body: bytes)
        try Task.checkCancellation()
        let response = try await http.perform(RelayRequest(url: base.appendingPathComponent(operation), method: "POST",
            headers: proof.merging(["Content-Type": "application/json", "Cache-Control": "no-store"]) { _, value in value }, body: bytes))
        guard response.body.count <= 2_100_000 else { throw PolicyError.auditUnavailable }
        if !(200...299).contains(response.status) {
            struct Refusal: Decodable { let error: String }
            let code = response.body.count <= 4096 ? (try? JSONDecoder().decode(Refusal.self, from: response.body).error) : nil
            if code == "archive_full" { throw AuditArchiveFailure.full }
            if code == "archive_writer_mismatch" || code == "archive_writer_required" { throw AuditArchiveFailure.writerMismatch }
            throw RelayError.httpRefused(response.status)
        }
        return response.body
    }
    private func validate(_ block: AuditArchiveBlock) throws {
        guard block.account_id == member.route.account, block.room_id == member.route.room else { throw PolicyError.invalid }
    }
    public func append(_ block: AuditArchiveBlock) async throws {
        try validate(block)
        _ = try await request("archive/append", bytes: ProtocolCodec.encode(block), limit: 66_560)
    }
    public func checkpoint(_ block: AuditArchiveBlock) async throws {
        try validate(block)
        _ = try await request("archive/checkpoint", bytes: ProtocolCodec.encode(block), limit: 2_100_000)
    }
    public func read(account: String, room: String, sequence: Int64) async throws -> [AuditArchiveBlock] {
        try await read(account: account, room: room, epoch: 0, sequence: sequence)
    }
    public func read(account: String, room: String, epoch: Int64, sequence: Int64) async throws -> [AuditArchiveBlock] {
        guard account == member.route.account, room == member.route.room else { throw PolicyError.invalid }
        let bytes = try ProtocolCodec.encode(AuditArchiveRead(account_id: account, room_id: room, sequence: sequence, epoch: epoch))
        let page = try ProtocolCodec.decode(AuditArchivePage.self, from: await request("archive/read", bytes: bytes, limit: 4096))
        guard page.account_id == account, page.room_id == room, page.epoch ?? 0 == epoch else { throw PolicyError.tampered }
        return page.blocks
    }
}

/// Recovery never bypasses the Policy biometric challenge, preserves the source,
/// and cannot create a new authority after loss without an executor fence.
@MainActor public enum PhoneArchiveRecovery {
    public static func restore(client: any AuditArchiveClient, cipher: any AuditArchiveCipher,
        archive: any AuditArchiveAnchorStore, source: any AuditJournal, checkpoints: any AuditCheckpointStore,
        destination: any AuditJournal, destinationCheckpoints: any AuditRecoveryCheckpointStore,
        account: String, actor: String, sessionID: String, biometric: any Biometric,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) async throws -> AuditLog {
        let session = PhoneInput(now: now).session(account: account, actor: actor, session: sessionID,
            device: actor, project: "audit-recovery", destinationKind: .software)
        let retired = try checkpoints.load()
        if retired.retired == true, retired.recoveryTarget == destinationCheckpoints.recoverySlotID,
           try destinationCheckpoints.load() != .empty || destinationCheckpoints.loadPending() != nil {
            // A crash may leave the fully staged destination before the app's
            // active-slot pointer advanced. Reconcile that same pinned slot with
            // another fresh biometric; never create a second authority domain.
            let original = try source.read(), state = try archive.loadArchive()
            let recovered = try await AuditLog.recover(journal: destination, checkpoints: destinationCheckpoints,
                retention: AuditRetention(), session: session, biometric: biometric, clock: now)
            guard try checkpoints.load() == retired, try source.read() == original,
                  try archive.loadArchive() == state else { throw PolicyError.tampered }
            return recovered
        }
        return try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: archive,
            sourceJournal: source, sourceCheckpoints: checkpoints, destinationJournal: destination,
            destinationCheckpoints: destinationCheckpoints, retention: AuditRetention(), session: session,
            biometric: biometric, clock: now)
    }
}
