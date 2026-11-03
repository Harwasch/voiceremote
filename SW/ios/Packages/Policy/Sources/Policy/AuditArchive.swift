import Foundation
import VoiceRemoteProtocol

@MainActor public protocol AuditArchiveCipher: AnyObject {
    /// Phone-only AEAD with fresh nonces; authenticate the exact context. No default cipher.
    func seal(_ plaintext: Data, context: Data) throws -> Data
    func open(_ ciphertext: Data, context: Data) throws -> Data
}
public enum AuditArchiveFailure: Error { case full, writerMismatch, lostCopy, unsupported }
@MainActor public protocol AuditArchiveClient: AnyObject {
    func append(_ block: AuditArchiveBlock) async throws
    func checkpoint(_ block: AuditArchiveBlock) async throws
    func read(account: String, room: String, sequence: Int64) async throws -> [AuditArchiveBlock]
    func read(account: String, room: String, epoch: Int64, sequence: Int64) async throws -> [AuditArchiveBlock]
}
extension AuditArchiveClient {
    public func checkpoint(_ block: AuditArchiveBlock) async throws { throw AuditArchiveFailure.unsupported }
    public func read(account: String, room: String, epoch: Int64, sequence: Int64) async throws -> [AuditArchiveBlock] {
        guard epoch == 0 else { throw AuditArchiveFailure.unsupported }
        return try await read(account: account, room: room, sequence: sequence)
    }
}
public struct AuditArchiveAnchor: Codable, Equatable, Sendable {
    public let account: String
    public let room: String
    public let count: Int64
    public let head: String
    public let journal: AuditCheckpoint
    public let epoch: Int64?
    public let baseHead: String?
    public let snapshotHash: String?
    public init(account: String, room: String) {
        self.init(account: account, room: room, count: 0, head: AuditCheckpoint.empty.head, journal: .empty)
    }
    init(account: String, room: String, count: Int64, head: String, journal: AuditCheckpoint,
         epoch: Int64? = nil, baseHead: String? = nil, snapshotHash: String? = nil) {
        self.account = account; self.room = room; self.count = count; self.head = head; self.journal = journal
        self.epoch = epoch; self.baseHead = baseHead; self.snapshotHash = snapshotHash
    }
    var verificationCheckpoint: AuditCheckpoint {
        AuditCheckpoint(count: journal.count, head: journal.head, compactionHash: snapshotHash, authorityID: journal.authorityID, authoritySessionHash: journal.authoritySessionHash)
    }
}
public struct AuditArchivePending: Codable, Equatable, Sendable {
    public let block: AuditArchiveBlock
    public let next: AuditArchiveAnchor
    public let isCheckpoint: Bool?
    init(block: AuditArchiveBlock, next: AuditArchiveAnchor, isCheckpoint: Bool? = nil) {
        self.block = block; self.next = next; self.isCheckpoint = isCheckpoint
    }
}
public enum AuditArchiveHealth: String, Codable, Sendable { case verified, unverified, lostCopy, writerMismatch }
public struct AuditArchiveState: Codable, Equatable, Sendable {
    public let anchor: AuditArchiveAnchor
    public let pending: AuditArchivePending?
    public let health: AuditArchiveHealth?
    public let lastVerifiedAt: Int64?
    public init(anchor: AuditArchiveAnchor, pending: AuditArchivePending? = nil,
                health: AuditArchiveHealth? = nil, lastVerifiedAt: Int64? = nil) {
        self.anchor = anchor; self.pending = pending; self.health = health; self.lastVerifiedAt = lastVerifiedAt
    }
}
/// Independent atomic durable storage; never reconstruct from the relay. Persist
/// exact sealed intent before submission, and surface health in the application.
@MainActor public protocol AuditArchiveAnchorStore: AnyObject {
    func loadArchive() throws -> AuditArchiveState
    func saveArchive(_ state: AuditArchiveState) throws
}
public enum AuditArchive {
    public static let maximumBlocks: Int64 = 128
    public static let verificationInterval: Int64 = 24 * 60 * 60 * 1000 // TBC: also every eighth append and every rollover.
    static func context(account: String, room: String, sequence: Int64, previous: String, epoch: Int64 = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["voiceremote-audit-archive-v2", account, room, epoch, sequence, previous], options: [.withoutEscapingSlashes])
    }
    public static func hash(_ block: AuditArchiveBlock) throws -> String {
        PayloadDigest.sha256(try JSONSerialization.data(withJSONObject: ["voiceremote-audit-archive-v2", block.account_id,
            block.room_id, block.epoch ?? 0, block.sequence, block.previous_hash, block.ciphertext], options: [.withoutEscapingSlashes]))
    }
    // Encrypted length prefix + zero padding. Single records share the 2 KiB bucket;
    // subsequent powers of two hide exact event lengths. Padding is authenticated.
    static func pad(_ bytes: Data) throws -> Data {
        guard bytes.count <= 1_048_572 else { throw PolicyError.auditUnavailable }
        var size = 2048
        while size < bytes.count + 4 { size *= 2 }
        let n = UInt32(bytes.count)
        var result = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        result.append(bytes); result.append(Data(repeating: 0, count: size - result.count)); return result
    }
    static func unpad(_ bytes: Data) throws -> Data {
        guard bytes.count >= 2048, bytes.count <= 1_048_576, bytes.count.nonzeroBitCount == 1 else { throw PolicyError.tampered }
        let n = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard n > 0, n <= bytes.count - 4, bytes.dropFirst(n + 4).allSatisfy({ $0 == 0 }) else { throw PolicyError.tampered }
        return Data(bytes.dropFirst(4).prefix(n))
    }
    @MainActor static func sealed(_ bytes: Data, anchor: AuditArchiveAnchor, cipher: any AuditArchiveCipher,
                                  epoch: Int64, sequence: Int64, previous: String) throws -> AuditArchiveBlock {
        let ciphertext = try cipher.seal(pad(bytes), context: context(account: anchor.account, room: anchor.room,
            sequence: sequence, previous: previous, epoch: epoch)).base64EncodedString()
        let b = AuditArchiveBlock(account_id: anchor.account, room_id: anchor.room, sequence: sequence,
            previous_hash: previous, ciphertext: ciphertext, block_hash: AuditCheckpoint.empty.head, epoch: epoch)
        return AuditArchiveBlock(account_id: b.account_id, room_id: b.room_id, sequence: b.sequence,
            previous_hash: b.previous_hash, ciphertext: b.ciphertext, block_hash: try hash(b), epoch: epoch)
    }
    @MainActor public static func replicate(log: AuditLog, client: any AuditArchiveClient,
        cipher: any AuditArchiveCipher, store: any AuditArchiveAnchorStore,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> AuditArchiveAnchor {
        let state = try store.loadArchive(), anchor = state.anchor
        guard log.accountHash == nil || log.accountHash == PayloadDigest.sha256(Data(anchor.account.utf8)) else { throw PolicyError.tampered }
        if state.pending?.isCheckpoint == true { return try await submit(log: log, client: client, cipher: cipher, store: store, now: now) }
        if anchor.count >= maximumBlocks { return try await rollover(log: log, client: client, cipher: cipher, store: store, now: now) }
        if state.pending == nil {
            let batch = try log.exportBatch(after: anchor.journal)
            if batch.bytes.isEmpty {
                try await verifyScheduled(client: client, cipher: cipher, store: store, now: now)
                return anchor
            }
            let block = try sealed(batch.bytes, anchor: anchor, cipher: cipher, epoch: anchor.epoch ?? 0, sequence: anchor.count, previous: anchor.head)
            _ = try ProtocolCodec.encode(block)
            let next = AuditArchiveAnchor(account: anchor.account, room: anchor.room, count: anchor.count + 1,
                head: block.block_hash, journal: batch.checkpoint, epoch: anchor.epoch, baseHead: anchor.baseHead, snapshotHash: anchor.snapshotHash)
            try store.saveArchive(AuditArchiveState(anchor: anchor, pending: AuditArchivePending(block: block, next: next),
                health: state.health, lastVerifiedAt: state.lastVerifiedAt))
        }
        do { return try await submit(log: log, client: client, cipher: cipher, store: store, now: now) }
        catch AuditArchiveFailure.full { return try await rollover(log: log, client: client, cipher: cipher, store: store, now: now) }
    }
    @MainActor private static func submit(log: AuditLog, client: any AuditArchiveClient, cipher: any AuditArchiveCipher,
        store: any AuditArchiveAnchorStore, now: Int64) async throws -> AuditArchiveAnchor {
        let state = try store.loadArchive(), anchor = state.anchor
        guard let pending = state.pending else { throw PolicyError.invalid }
        let block = pending.block
        _ = try ProtocolCodec.encode(block)
        guard block.account_id == anchor.account, block.room_id == anchor.room, block.block_hash == (try hash(block)),
              pending.next.head == block.block_hash, pending.next.account == anchor.account, pending.next.room == anchor.room else { throw PolicyError.tampered }
        let data = try unpad(cipher.open(Data(base64Encoded: block.ciphertext)!, context: context(account: anchor.account,
            room: anchor.room, sequence: block.sequence, previous: block.previous_hash, epoch: block.epoch ?? 0)))
        if pending.isCheckpoint == true {
            guard block.epoch == (anchor.epoch ?? 0) + 1, block.sequence == 0, pending.next.count == 1,
                  pending.next.baseHead == block.previous_hash else { throw PolicyError.tampered }
            _ = try AuditLog.verify(data, against: pending.next.verificationCheckpoint)
            _ = try log.exportBatch(after: pending.next.journal) // Still an anchored local prefix, even after newer events.
        } else {
            guard block.sequence == anchor.count, block.epoch ?? 0 == anchor.epoch ?? 0, block.previous_hash == anchor.head,
                  pending.next.count == anchor.count + 1 else { throw PolicyError.tampered }
            let batch = try log.exportBatch(after: anchor.journal, through: pending.next.journal.count)
            guard batch.bytes == data, batch.checkpoint == pending.next.journal else { throw PolicyError.tampered }
        }
        do {
            if pending.isCheckpoint == true { try await client.checkpoint(block) } else { try await client.append(block) }
        } catch AuditArchiveFailure.writerMismatch {
            guard try store.loadArchive() == state else { throw PolicyError.locked }
            try store.saveArchive(AuditArchiveState(anchor: anchor, pending: pending, health: .writerMismatch, lastVerifiedAt: state.lastVerifiedAt))
            throw AuditArchiveFailure.writerMismatch
        }
        guard try store.loadArchive() == state else { throw PolicyError.locked }
        try store.saveArchive(AuditArchiveState(anchor: pending.next, health: state.health == .lostCopy ? .lostCopy : .unverified, lastVerifiedAt: state.lastVerifiedAt))
        try await verifyScheduled(client: client, cipher: cipher, store: store, now: now, force: pending.isCheckpoint == true)
        return pending.next
    }
    /// Signed encrypted checkpoint starts a fresh epoch and authorizes old detail
    /// pruning. Includes all local replay/ownership/revocation state, even a pending
    /// append that the relay refused for capacity. Exact rollover intent is durable.
    @MainActor public static func rollover(log: AuditLog, client: any AuditArchiveClient, cipher: any AuditArchiveCipher,
        store: any AuditArchiveAnchorStore, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> AuditArchiveAnchor {
        let state = try store.loadArchive(), anchor = state.anchor
        guard log.accountHash == nil || log.accountHash == PayloadDigest.sha256(Data(anchor.account.utf8)) else { throw PolicyError.tampered }
        if state.pending?.isCheckpoint == true { return try await submit(log: log, client: client, cipher: cipher, store: store, now: now) }
        let trusted = try log.exportCheckpoint(), snapshot = try log.compactionSnapshot()
        if trusted.authorityID == anchor.journal.authorityID {
            _ = try log.exportBatch(after: anchor.journal)
        } else {
            // Only the explicit fenced reset path can cross authority domains.
            // An unrelated empty journal must never prune a trusted archive.
            guard trusted.authorityID != nil, trusted.authoritySessionHash != nil,
                  log.records.contains(where: { $0.event == .authorityReset }) else { throw PolicyError.tampered }
        }
        // Read the old head and resolve a lost append acknowledgement before linking epochs.
        let tail = try await client.read(account: anchor.account, room: anchor.room, epoch: anchor.epoch ?? 0, sequence: max(0, anchor.count - 1))
        var expected: [AuditArchiveBlock] = tail
        if anchor.count > 0 {
            guard let last = expected.first, last.sequence == anchor.count - 1, last.block_hash == anchor.head,
                  last.block_hash == (try hash(last)) else { throw AuditArchiveFailure.lostCopy }
            expected.removeFirst()
        }
        var previous = anchor.head
        if !expected.isEmpty {
            guard expected.count == 1, let pending = state.pending, expected[0] == pending.block else { throw AuditArchiveFailure.lostCopy }
            previous = expected[0].block_hash
        }
        guard try store.loadArchive() == state, try log.exportCheckpoint() == trusted else { throw PolicyError.locked }
        let block = try sealed(snapshot.bytes, anchor: anchor, cipher: cipher, epoch: (anchor.epoch ?? 0) + 1, sequence: 0, previous: previous)
        let next = AuditArchiveAnchor(account: anchor.account, room: anchor.room, count: 1, head: block.block_hash,
            journal: AuditCheckpoint(count: trusted.count, head: trusted.head, authorityID: trusted.authorityID, authoritySessionHash: trusted.authoritySessionHash), epoch: block.epoch,
            baseHead: previous, snapshotHash: snapshot.checkpoint.compactionHash)
        try store.saveArchive(AuditArchiveState(anchor: anchor, pending: AuditArchivePending(block: block, next: next, isCheckpoint: true),
            health: state.health, lastVerifiedAt: state.lastVerifiedAt))
        return try await submit(log: log, client: client, cipher: cipher, store: store, now: now)
    }
    /// Call on foreground/reconnect and a daily scheduler, also invoked by replication.
    /// Health is durable and visible to callers; a successful upload is not proof of retention.
    @MainActor public static func verifyScheduled(client: any AuditArchiveClient, cipher: any AuditArchiveCipher,
        store: any AuditArchiveAnchorStore, now: Int64, force: Bool = false) async throws {
        let state = try store.loadArchive()
        guard now >= 0, now >= (state.lastVerifiedAt ?? 0) else { throw PolicyError.clock }
        if !force, let last = state.lastVerifiedAt, now - last < verificationInterval,
           state.anchor.count % 8 != 0, state.health != .lostCopy { return }
        do {
            _ = try await verifiedBytes(client: client, cipher: cipher, anchor: state.anchor, against: state.anchor.journal)
        } catch {
            guard try store.loadArchive() == state else { throw PolicyError.locked }
            try store.saveArchive(AuditArchiveState(anchor: state.anchor, pending: state.pending, health: .lostCopy, lastVerifiedAt: state.lastVerifiedAt))
            throw AuditArchiveFailure.lostCopy
        }
        guard try store.loadArchive() == state else { throw PolicyError.locked }
        try store.saveArchive(AuditArchiveState(anchor: state.anchor, pending: state.pending, health: .verified, lastVerifiedAt: now))
    }
    @MainActor public static func verifiedBytes(client: any AuditArchiveClient, cipher: any AuditArchiveCipher,
        anchor: AuditArchiveAnchor, against checkpoint: AuditCheckpoint) async throws -> Data {
        guard anchor.count >= 0, anchor.count <= maximumBlocks, anchor.journal.count == checkpoint.count,
              anchor.journal.head == checkpoint.head, anchor.journal.authorityID == checkpoint.authorityID,
              anchor.journal.authoritySessionHash == checkpoint.authoritySessionHash else { throw PolicyError.tampered }
        var sequence: Int64 = 0, head = anchor.baseHead ?? AuditCheckpoint.empty.head, result = Data(), total = 0
        while sequence < anchor.count {
            let page = try await client.read(account: anchor.account, room: anchor.room, epoch: anchor.epoch ?? 0, sequence: sequence)
            guard !page.isEmpty, page.count <= 8, sequence + Int64(page.count) <= anchor.count else { throw PolicyError.tampered }
            for block in page {
                _ = try ProtocolCodec.encode(block); total += try canonical(block).count
                guard total <= 2_097_152, block.account_id == anchor.account, block.room_id == anchor.room,
                      block.epoch ?? 0 == anchor.epoch ?? 0, block.sequence == sequence, block.previous_hash == head,
                      block.block_hash == (try hash(block)), let sealed = Data(base64Encoded: block.ciphertext),
                      sealed.base64EncodedString() == block.ciphertext else { throw PolicyError.tampered }
                let plaintext = try unpad(cipher.open(sealed, context: context(account: anchor.account, room: anchor.room,
                    sequence: sequence, previous: head, epoch: anchor.epoch ?? 0)))
                guard plaintext.last == 10 else { throw PolicyError.tampered }
                result.append(plaintext); guard result.count <= AuditLog.maximumJournalBytes else { throw PolicyError.auditUnavailable }
                sequence += 1; head = block.block_hash
            }
        }
        guard head == anchor.head else { throw PolicyError.tampered }
        let records = try AuditLog.verify(result, against: anchor.verificationCheckpoint)
        guard records.compactMap(\.accountEnvelope).allSatisfy({ $0.accountHash == PayloadDigest.sha256(Data(anchor.account.utf8)) }) else { throw PolicyError.tampered }
        return result
    }
}
/// Synthetic ciphertext-only transport; no production encryption/key adapter.
@MainActor public final class FakeAuditArchiveClient: AuditArchiveClient {
    public var blocks: [AuditArchiveBlock] = []
    public var loseNextAcknowledgement = false
    public var refuseWriter = false
    public private(set) var epoch: Int64 = 0
    public init() {}
    public func checkpoint(_ block: AuditArchiveBlock) async throws {
        if refuseWriter { throw AuditArchiveFailure.writerMismatch }
        if block.epoch == epoch, blocks.first == block { return }
        guard block.epoch == epoch + 1, block.sequence == 0,
              block.previous_hash == (blocks.last?.block_hash ?? AuditCheckpoint.empty.head),
              block.block_hash == (try AuditArchive.hash(block)) else { throw PolicyError.tampered }
        blocks = [block]; epoch += 1
        if loseNextAcknowledgement { loseNextAcknowledgement = false; throw PolicyError.auditUnavailable }
    }
    public func append(_ block: AuditArchiveBlock) async throws {
        if refuseWriter { throw AuditArchiveFailure.writerMismatch }
        _ = try ProtocolCodec.encode(block)
        guard block.epoch ?? 0 == epoch, block.block_hash == (try AuditArchive.hash(block)) else { throw PolicyError.tampered }
        if Int(block.sequence) < blocks.count { guard blocks[Int(block.sequence)] == block else { throw PolicyError.tampered } }
        else {
            guard block.sequence == Int64(blocks.count), block.previous_hash == (blocks.last?.block_hash ?? AuditCheckpoint.empty.head) else { throw PolicyError.invalid }
            let total = try blocks.reduce(0) { try $0 + canonical($1).count }
            guard blocks.count < 128, try total + canonical(block).count <= 2_097_152 else { throw AuditArchiveFailure.full }
            blocks.append(block)
        }
        if loseNextAcknowledgement { loseNextAcknowledgement = false; throw PolicyError.auditUnavailable }
    }
    public func read(account: String, room: String, sequence: Int64) async throws -> [AuditArchiveBlock] {
        try await read(account: account, room: room, epoch: 0, sequence: sequence)
    }
    public func read(account: String, room: String, epoch: Int64, sequence: Int64) async throws -> [AuditArchiveBlock] {
        guard epoch == self.epoch else { throw PolicyError.tampered }
        return Array(blocks.dropFirst(Int(sequence)).prefix(8))
    }
}
