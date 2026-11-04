import Foundation

/// Capsule digest lives in the independent checkpoint. Replay reservations,
/// cancellation ownership, dismissals and revocations outlive detailed history.
struct AuditCompaction: Codable {
    static let replayEvents: Set<AuditEvent> = [.accountBound, .ownerCompleted, .queued, .dismissed, .grantRevoked, .sessionRevoked, .authorityReset]
    let base: AuditCheckpoint
    let timestamp: Int64
    let replay: [AuditRecord]
}

public struct AuditExport: Sendable {
    public let checkpoint: AuditCheckpoint
    public let bytes: Data
}

extension AuditLog {
    /// Trusted checkpoint export, never derived from remote archive metadata.
    public func exportCheckpoint() throws -> AuditCheckpoint { try checkIntegrity(); return checkpoint }

    func minimumTime() throws -> Int64 {
        if checkpoint.compactionHash != nil {
            let first = try journal.read().split(separator: 10).first ?? Data.SubSequence()
            let capsule = try JSONDecoder().decode(AuditCompaction.self, from: Data(first))
            // A recovery event may explicitly start a new clock epoch.
            return records.last(where: { $0.sequence >= capsule.base.count })?.timestamp ?? capsule.timestamp
        }
        return records.last?.timestamp ?? 0
    }

    func exportBatch(after previous: AuditCheckpoint, through end: Int? = nil) throws -> AuditExport {
        try checkIntegrity()
        guard previous.authorityID == checkpoint.authorityID, previous.count >= 0, previous.count <= checkpoint.count else { throw PolicyError.tampered }
        let base: AuditCheckpoint
        if checkpoint.compactionHash != nil {
            let line = try journal.read().split(separator: 10).first!
            base = try JSONDecoder().decode(AuditCompaction.self, from: Data(line)).base
        } else { base = .empty }
        guard previous.count >= base.count,
              previous.head == (previous.count == base.count ? base.head : records.first(where: { $0.sequence == previous.count - 1 })?.recordHash) else {
            throw PolicyError.tampered
        }
        var bytes = Data(), next = AuditCheckpoint(count: previous.count, head: previous.head, authorityID: checkpoint.authorityID, authoritySessionHash: checkpoint.authoritySessionHash)
        for record in records where record.sequence >= previous.count && record.sequence < (end ?? Int.max) {
            var line = try canonical(record); line.append(10)
            if bytes.count + line.count > 24_000 { break }
            bytes.append(line); next = AuditCheckpoint(count: record.sequence + 1, head: record.recordHash, authorityID: checkpoint.authorityID, authoritySessionHash: checkpoint.authoritySessionHash)
        }
        if let end, next.count != end { throw PolicyError.tampered }
        guard next.count > previous.count || previous.count == checkpoint.count else { throw PolicyError.auditUnavailable }
        return AuditExport(checkpoint: next, bytes: bytes)
    }

    func compactionSnapshot() throws -> AuditExport {
        try checkIntegrity()
        var retained: [String: AuditRecord] = [:]
        for record in records where AuditCompaction.replayEvents.contains(record.event) {
            retained[record.event.rawValue + ":" + record.subjectHash] = record
        }
        let capsule = AuditCompaction(base: AuditCheckpoint(count: checkpoint.count, head: checkpoint.head, authorityID: checkpoint.authorityID, authoritySessionHash: checkpoint.authoritySessionHash),
            timestamp: try minimumTime(), replay: retained.values.sorted { $0.sequence < $1.sequence })
        let body = try canonical(capsule)
        guard body.count <= 1_048_571 else { throw PolicyError.auditUnavailable }
        let compacted = AuditCheckpoint(count: checkpoint.count, head: checkpoint.head,
            compactionHash: PayloadDigest.sha256(body), authorityID: checkpoint.authorityID, authoritySessionHash: checkpoint.authoritySessionHash)
        var bytes = body; bytes.append(10)
        _ = try Self.verify(bytes, against: compacted)
        return AuditExport(checkpoint: compacted, bytes: bytes)
    }

    /// Copy-on-write compaction to a NEW empty private journal. The old file is
    /// preserved. Publish the new file selection atomically with the checkpoint
    /// in the application adapter; old gates fail their next integrity check.
    /// The retained epoch (records or signed replay snapshot) is read back and verified.
    public func compact(into destination: any AuditJournal, client: any AuditArchiveClient,
        cipher: any AuditArchiveCipher, archiveStore: any AuditArchiveAnchorStore) async throws -> AuditLog {
        try checkIntegrity()
        let initial = try archiveStore.loadArchive()
        if initial.pending != nil || initial.anchor.count >= AuditArchive.maximumBlocks {
            _ = try await AuditArchive.rollover(log: self, client: client, cipher: cipher, store: archiveStore)
        }
        let original = try journal.read(), trusted = checkpoint, state = try archiveStore.loadArchive()
        guard state.pending == nil, try destination.read().isEmpty else { throw PolicyError.invalid }
        _ = try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: state.anchor, against: trusted)
        try checkIntegrity()
        guard checkpoint == trusted, try journal.read() == original, try archiveStore.loadArchive() == state,
              try destination.read().isEmpty else { throw PolicyError.tampered }
        let snapshot = try compactionSnapshot()
        let compacted = snapshot.checkpoint, bytes = snapshot.bytes
        try destination.append(bytes)
        try checkpoints.save(compacted)
        return try AuditLog(journal: destination, checkpoints: checkpoints, retention: retention)
    }
}
