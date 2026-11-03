import Foundation
import TrustedInput

extension AuditLog {
    /// Restore into a new journal AND new protected checkpoint slot. Preserve the
    /// damaged original bytes/head for inspection; retire the old authority slot.
    /// Never reset authority or trust a relay head.
    public static func recoverArchive(client: any AuditArchiveClient, cipher: any AuditArchiveCipher,
        archiveStore: any AuditArchiveAnchorStore, sourceJournal: any AuditJournal,
        sourceCheckpoints: any AuditCheckpointStore, destinationJournal: any AuditJournal,
        destinationCheckpoints: any AuditRecoveryCheckpointStore, retention: AuditRetention,
        session: InputSession, biometric: any Biometric, clock: () throws -> Int64) async throws -> AuditLog {
        let state = try archiveStore.loadArchive(), trusted = try sourceCheckpoints.load()
        let destinationID = destinationCheckpoints.recoverySlotID
        let original = try sourceJournal.read()
        guard !destinationID.isEmpty, destinationID.utf8.count <= 128,
              trusted.retired != true || trusted.recoveryTarget == destinationID,
              ObjectIdentifier(sourceCheckpoints) != ObjectIdentifier(destinationCheckpoints),
              ObjectIdentifier(sourceJournal) != ObjectIdentifier(destinationJournal),
              state.pending == nil, try sourceCheckpoints.loadPending() == nil,
              try destinationJournal.read().isEmpty, try destinationCheckpoints.load() == .empty,
              try destinationCheckpoints.loadPending() == nil else { throw PolicyError.auditUnavailable }
        let bytes = try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: state.anchor, against: trusted)
        let flat = state.anchor.verificationCheckpoint
        let history = try verify(bytes, against: flat)
        let sessionHash = identityDigest([session.account, session.actor, session.session])
        guard session.destinationKind == .software, session.account == state.anchor.account,
              trusted.authoritySessionHash == nil || trusted.authoritySessionHash == sessionHash,
              [session.account, session.actor, session.session, session.device, session.project].allSatisfy({
                  !$0.isEmpty && $0 != "*" && $0.unicodeScalars.count <= 128
              }), !history.contains(where: { $0.event == .sessionRevoked && $0.subjectHash == sessionHash }) else { throw PolicyError.invalid }
        let started = try clock()
        guard started >= 0, started <= 9_007_199_254_740_991 - 30_000 else { throw PolicyError.clock }
        let snapshot = RecoverySnapshot(checkpoint: trusted, pending: nil, journalHash: PayloadDigest.sha256(original),
            sessionHash: sessionHash, requestedTime: started, destinationSlotID: destinationID)
        let binding = PayloadDigest.sha256(try canonical(snapshot))
        let challenge = AuthenticationChallenge(id: UUID(), payloadHash: binding, issuedAt: started, expiresAt: started + 30_000)
        let result = try await biometric.authenticate(challenge), completed = try clock()
        guard result.challenge == challenge, completed >= started, completed < challenge.expiresAt,
              result.authenticatedAt >= started, result.authenticatedAt <= completed,
              result.credential == .biometric || result.credential == .passcode else { throw PolicyError.invalid }
        guard try sourceJournal.read() == original, try sourceCheckpoints.load() == trusted,
              try sourceCheckpoints.loadPending() == nil, try archiveStore.loadArchive() == state,
              destinationCheckpoints.recoverySlotID == destinationID,
              try destinationJournal.read().isEmpty, try destinationCheckpoints.load() == .empty,
              try destinationCheckpoints.loadPending() == nil else { throw PolicyError.tampered }
        let recovered = try makeRecord(event: .recovered, subject: sessionHash, payloadHash: binding,
            actor: session.actor, now: completed, checkpoint: flat)
        var complete = bytes; complete.append(try canonical(recovered)); complete.append(10)
        let next = AuditCheckpoint(count: flat.count + 1, head: recovered.recordHash, compactionHash: flat.compactionHash, authorityID: flat.authorityID, authoritySessionHash: flat.authoritySessionHash)
        _ = try verify(complete, against: next)
        // Retire BEFORE any destination intent can become recoverable. A crash or
        // uncertain save denies old execution and permits authenticated retry from
        // this same forensic count/head, without creating two live replay domains.
        try sourceCheckpoints.save(AuditCheckpoint(count: trusted.count, head: trusted.head,
            compactionHash: trusted.compactionHash, retired: true, recoveryTarget: destinationID, authorityID: trusted.authorityID, authoritySessionHash: trusted.authoritySessionHash))
        try destinationCheckpoints.savePending(AuditPending(base: .empty, next: next, recordBytes: complete))
        try destinationJournal.append(complete)
        try destinationCheckpoints.save(next)
        try destinationCheckpoints.savePending(nil)
        return try AuditLog(journal: destinationJournal, checkpoints: destinationCheckpoints, retention: retention)
    }

    private struct RecoverySnapshot: Encodable {
        let checkpoint: AuditCheckpoint
        let pending: AuditPending?
        let journalHash: String
        let sessionHash: String
        let requestedTime: Int64
        let destinationSlotID: String?
    }

    /// Explicit phone-admin operation. Obtains fresh authentication bound to the
    /// exact damaged/pending snapshot and proposed clock epoch, then preserves all
    /// history and appends a recovery event. Never resets the journal/checkpoint.
    /// A new PolicyGate is required; old gates fail their next integrity check.
    public static func recover(journal: any AuditJournal, checkpoints: any AuditCheckpointStore,
                               retention: AuditRetention, session: InputSession,
                               biometric: any Biometric, clock: () throws -> Int64) async throws -> AuditLog {
        let checkpoint = try checkpoints.load(), pending = try checkpoints.loadPending()
        guard checkpoint.retired != true else { throw PolicyError.auditUnavailable }
        let original = try journal.read()
        let (complete, head) = try reconciled(original, checkpoint: checkpoint, pending: pending)
        let history = try verify(complete, against: head)
        let sessionHash = identityDigest([session.account, session.actor, session.session])
        guard session.destinationKind == .software,
              head.authoritySessionHash == nil || head.authoritySessionHash == sessionHash,
              [session.account, session.actor, session.session, session.device, session.project].allSatisfy({
                  !$0.isEmpty && $0 != "*" && $0.unicodeScalars.count <= 128
              }), !history.contains(where: { $0.event == .sessionRevoked && $0.subjectHash == sessionHash }) else {
            throw PolicyError.invalid
        }
        let started = try clock()
        guard started >= 0, started <= 9_007_199_254_740_991 - 30_000 else { throw PolicyError.clock }
        let snapshot = RecoverySnapshot(checkpoint: checkpoint, pending: pending,
            journalHash: PayloadDigest.sha256(original), sessionHash: sessionHash, requestedTime: started, destinationSlotID: nil)
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
        let next = AuditCheckpoint(count: head.count + 1, head: recovered.recordHash, compactionHash: head.compactionHash, authorityID: head.authorityID, authoritySessionHash: head.authoritySessionHash)
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
        if pending.base.compactionHash != nil {
            guard let newline = bytes.firstIndex(of: 10) else { throw PolicyError.tampered }
            let capsule = try JSONDecoder().decode(AuditCompaction.self, from: bytes.prefix(upTo: newline))
            count = capsule.base.count; end = newline + 1
        }
        if pending.base.count > count {
            for (offset, byte) in bytes.enumerated() where byte == 10 && offset >= end {
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
