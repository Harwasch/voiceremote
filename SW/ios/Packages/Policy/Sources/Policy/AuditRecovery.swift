import Foundation
import TrustedInput

extension AuditLog {
    private struct RecoverySnapshot: Encodable {
        let checkpoint: AuditCheckpoint
        let pending: AuditPending?
        let journalHash: String
        let sessionHash: String
        let requestedTime: Int64
    }

    /// Explicit phone-admin operation. Obtains fresh authentication bound to the
    /// exact damaged/pending snapshot and proposed clock epoch, then preserves all
    /// history and appends a recovery event. Never resets the journal/checkpoint.
    /// A new PolicyGate is required; old gates fail their next integrity check.
    public static func recover(journal: any AuditJournal, checkpoints: any AuditCheckpointStore,
                               retention: AuditRetention, session: InputSession,
                               biometric: any Biometric, clock: () throws -> Int64) async throws -> AuditLog {
        let checkpoint = try checkpoints.load(), pending = try checkpoints.loadPending()
        let original = try journal.read()
        let (complete, head) = try reconciled(original, checkpoint: checkpoint, pending: pending)
        let history = try verify(complete, against: head)
        let sessionHash = identityDigest([session.account, session.actor, session.session])
        guard session.destinationKind == .software,
              [session.account, session.actor, session.session, session.device, session.project].allSatisfy({
                  !$0.isEmpty && $0 != "*" && $0.unicodeScalars.count <= 128
              }), !history.contains(where: { $0.event == .sessionRevoked && $0.subjectHash == sessionHash }) else {
            throw PolicyError.invalid
        }
        let started = try clock()
        guard started >= 0, started <= 9_007_199_254_740_991 - 30_000 else { throw PolicyError.clock }
        let snapshot = RecoverySnapshot(checkpoint: checkpoint, pending: pending,
            journalHash: PayloadDigest.sha256(original), sessionHash: sessionHash, requestedTime: started)
        let binding = PayloadDigest.sha256(try canonical(snapshot))
        let challenge = AuthenticationChallenge(id: UUID(), payloadHash: binding, issuedAt: started, expiresAt: started + 30_000)
        let result = try await biometric.authenticate(challenge)
        let completed = try clock()
        guard result.challenge == challenge, completed >= started, completed < challenge.expiresAt,
              result.authenticatedAt >= started, result.authenticatedAt <= completed,
              result.credential == .biometric || result.credential == .passcode else { throw PolicyError.invalid }
        // Authentication suspends: reject any concurrent write or replacement.
        guard try journal.read() == original, try checkpoints.load() == checkpoint,
              try checkpoints.loadPending() == pending else { throw PolicyError.tampered }
        let recovered = try makeRecord(event: .recovered, subject: sessionHash, payloadHash: binding,
                                       actor: session.actor, now: completed, checkpoint: head)
        var recoveryBytes = try canonical(recovered); recoveryBytes.append(10)
        let next = AuditCheckpoint(count: head.count + 1, head: recovered.recordHash)
        var finalBytes = complete; finalBytes.append(recoveryBytes)
        _ = try verify(finalBytes, against: next)
        // Stage the reconciliation AND its recovery event as one durable intent.
        // A second crash cannot expose an unaudited repair as a healthy journal.
        var suffix = Data()
        if let pending, checkpoint == pending.base { suffix.append(pending.recordBytes) }
        suffix.append(recoveryBytes)
        try checkpoints.savePending(AuditPending(base: checkpoint, next: next, recordBytes: suffix))
        try journal.append(Data(finalBytes.dropFirst(original.count)))
        try checkpoints.save(next)
        try checkpoints.savePending(nil)
        return try AuditLog(journal: journal, checkpoints: checkpoints, retention: retention)
    }

    private static func reconciled(_ bytes: Data, checkpoint: AuditCheckpoint,
                                   pending: AuditPending?) throws -> (Data, AuditCheckpoint) {
        guard let pending else { _ = try verify(bytes, against: checkpoint); return (bytes, checkpoint) }
        guard checkpoint == pending.base || checkpoint == pending.next,
              pending.base.count >= 0, pending.next.count > pending.base.count else { throw PolicyError.tampered }
        // Find and authenticate the complete prefix already anchored before append.
        var count = 0, end = 0
        if pending.base.count > 0 {
            for (offset, byte) in bytes.enumerated() where byte == 10 {
                count += 1
                if count == pending.base.count { end = offset + 1; break }
            }
            guard count == pending.base.count else { throw PolicyError.tampered }
        }
        let prefix = Data(bytes.prefix(end))
        _ = try verify(prefix, against: pending.base)
        var expected = prefix; expected.append(pending.recordBytes)
        _ = try verify(expected, against: pending.next)
        guard expected.starts(with: bytes),
              checkpoint != pending.next || bytes == expected else { throw PolicyError.tampered }
        return (expected, pending.next)
    }
}
