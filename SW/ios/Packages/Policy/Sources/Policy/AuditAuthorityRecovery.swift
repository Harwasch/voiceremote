import Foundation
import TrustedInput

/// Trusted composition-root adapter, never a model tool. Before returning, durably
/// revoke all previous executor sessions, permits and approval credentials, enroll
/// the new authority ID (the policy_version suffix), and return a NEW phone session.
/// Retries for the same next ID are idempotent and return the same durable session.
/// There is deliberately no permissive/default implementation.
@MainActor public protocol AuditAuthorityFence: AnyObject {
    func replaceAuthority(account: String, previous: String?, next: String) async throws -> InputSession
}

extension AuditLog {
    private struct AuthorityLoss: Encodable {
        let source: AuditCheckpoint
        let pending: AuditPending?
        let damagedHash: String
        let administrator: String
        let destination: String
        let nextAuthority: String
        let requestedTime: Int64
    }

    /// Explicit loss acceptance, distinct from verified history recovery. Preserves
    /// damaged originals and commits an authorityReset audit event in a new chain.
    /// Lost reservations cannot be reconstructed: a required executor fence makes
    /// old authority unusable, and a fresh session/approval domain starts empty.
    public static func startNewAuthority(sourceJournal: any AuditJournal, sourceCheckpoints: any AuditCheckpointStore,
        destinationJournal: any AuditJournal, destinationCheckpoints: any AuditRecoveryCheckpointStore,
        retention: AuditRetention, session: InputSession, biometric: any Biometric,
        fence: any AuditAuthorityFence, clock: () throws -> Int64) async throws -> (AuditLog, InputSession) {
        let source = try sourceCheckpoints.load(), pending = try sourceCheckpoints.loadPending(), original = try sourceJournal.read()
        let target = destinationCheckpoints.recoverySlotID
        guard !target.isEmpty, target.utf8.count <= 128, session.destinationKind == .software,
              [session.account, session.actor, session.session, session.device, session.project].allSatisfy({
                  !$0.isEmpty && $0 != "*" && $0.unicodeScalars.count <= 128
              }), source.retired != true || source.recoveryTarget == target,
              ObjectIdentifier(sourceCheckpoints) != ObjectIdentifier(destinationCheckpoints),
              ObjectIdentifier(sourceJournal) != ObjectIdentifier(destinationJournal),
              try destinationCheckpoints.load() == .empty, try destinationCheckpoints.loadPending() == nil,
              try destinationJournal.read().isEmpty else { throw PolicyError.invalid }
        let started = try clock()
        guard started >= 0, started <= 9_007_199_254_740_991 - 30_000 else { throw PolicyError.clock }
        let authority = PayloadDigest.sha256(Data(("voiceremote-new-authority-v1:" + target).utf8))
        let loss = AuthorityLoss(source: source, pending: pending, damagedHash: PayloadDigest.sha256(original),
            administrator: identityDigest([session.account, session.actor, session.session]), destination: target,
            nextAuthority: authority, requestedTime: started)
        let binding = PayloadDigest.sha256(try canonical(loss))
        let challenge = AuthenticationChallenge(id: UUID(), payloadHash: binding, issuedAt: started, expiresAt: started + 30_000)
        let result = try await biometric.authenticate(challenge), authenticated = try clock()
        guard result.challenge == challenge, authenticated >= started, authenticated < challenge.expiresAt,
              result.authenticatedAt >= started, result.authenticatedAt <= authenticated,
              result.credential == .biometric || result.credential == .passcode else { throw PolicyError.invalid }
        guard try sourceJournal.read() == original, try sourceCheckpoints.load() == source,
              try sourceCheckpoints.loadPending() == pending, destinationCheckpoints.recoverySlotID == target,
              try destinationCheckpoints.load() == .empty, try destinationCheckpoints.loadPending() == nil,
              try destinationJournal.read().isEmpty else { throw PolicyError.tampered }
        let retired = AuditCheckpoint(count: source.count, head: source.head, compactionHash: source.compactionHash,
            retired: true, recoveryTarget: target, authorityID: source.authorityID, authoritySessionHash: source.authoritySessionHash)
        try sourceCheckpoints.save(retired)
        let fresh = try await fence.replaceAuthority(account: session.account, previous: source.authorityID, next: authority)
        let completed = try clock()
        guard completed >= authenticated, completed < challenge.expiresAt,
              fresh.account == session.account, fresh.actor == session.actor, fresh.session != session.session,
              fresh.destinationKind == .software,
              [fresh.account, fresh.actor, fresh.session, fresh.device, fresh.project].allSatisfy({
                  !$0.isEmpty && $0 != "*" && $0.unicodeScalars.count <= 128
              }), try sourceJournal.read() == original, try sourceCheckpoints.load() == retired,
              try sourceCheckpoints.loadPending() == pending, destinationCheckpoints.recoverySlotID == target,
              try destinationCheckpoints.load() == .empty, try destinationCheckpoints.loadPending() == nil,
              try destinationJournal.read().isEmpty else { throw PolicyError.tampered }
        let sessionHash = identityDigest([fresh.account, fresh.actor, fresh.session])
        let base = AuditCheckpoint(count: 0, head: AuditCheckpoint.empty.head, authorityID: authority, authoritySessionHash: sessionHash)
        let record = try makeRecord(event: .authorityReset, subject: sessionHash, payloadHash: binding,
            actor: fresh.actor, now: completed, checkpoint: base)
        var bytes = try canonical(record); bytes.append(10)
        let next = AuditCheckpoint(count: 1, head: record.recordHash, authorityID: authority, authoritySessionHash: sessionHash)
        _ = try verify(bytes, against: next)
        try destinationCheckpoints.savePending(AuditPending(base: .empty, next: next, recordBytes: bytes))
        try destinationJournal.append(bytes)
        try destinationCheckpoints.save(next)
        try destinationCheckpoints.savePending(nil)
        return (try AuditLog(journal: destinationJournal, checkpoints: destinationCheckpoints, retention: retention), fresh)
    }
}
