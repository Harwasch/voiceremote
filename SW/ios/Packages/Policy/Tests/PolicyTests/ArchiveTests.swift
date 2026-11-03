import Foundation
import Testing
import TrustedInput
import VoiceRemoteProtocol
@testable import Policy

@MainActor final class ArchiveStore: AuditArchiveAnchorStore {
    var state: AuditArchiveState
    init(account: String = "test-account", room: String = "fixture-room") {
        state = AuditArchiveState(anchor: AuditArchiveAnchor(account: account, room: room))
    }
    func loadArchive() throws -> AuditArchiveState { state }
    func saveArchive(_ state: AuditArchiveState) throws { self.state = state }
}

/// Synthetic authenticated reversible fixture; NOT a cryptographic implementation.
/// Real AEAD and key storage remain application adapter responsibilities.
@MainActor final class FixtureArchiveCipher: AuditArchiveCipher {
    private let key = UUID().uuidString
    var fail = false
    func seal(_ plaintext: Data, context: Data) throws -> Data {
        if fail { throw PolicyError.invalid }
        let hidden = Data(plaintext.map { $0 ^ 0xa5 })
        var input = Data(key.utf8); input.append(context); input.append(hidden)
        var sealed = Data(PayloadDigest.sha256(input).utf8); sealed.append(hidden)
        return sealed
    }
    func open(_ ciphertext: Data, context: Data) throws -> Data {
        if fail { throw PolicyError.invalid }
        guard ciphertext.count >= 64 else { throw PolicyError.tampered }
        let hidden = Data(ciphertext.dropFirst(64))
        var input = Data(key.utf8); input.append(context); input.append(hidden)
        guard Data(PayloadDigest.sha256(input).utf8) == ciphertext.prefix(64) else { throw PolicyError.tampered }
        return Data(hidden.map { $0 ^ 0xa5 })
    }
}

@MainActor final class VanishingArchiveClient: AuditArchiveClient {
    var reads = 0
    func append(_ block: AuditArchiveBlock) async throws {}
    func read(account: String, room: String, sequence: Int64) async throws -> [AuditArchiveBlock] { reads += 1; return [] }
}

@MainActor final class FixtureAuthorityFence: AuditAuthorityFence {
    let fresh: InputSession
    var calls = 0
    var handler: (() async throws -> InputSession)?
    init(_ fresh: InputSession) { self.fresh = fresh }
    func replaceAuthority(account: String, previous: String?, next: String) async throws -> InputSession {
        calls += 1
        if let handler { return try await handler() }
        return fresh
    }
}

@Suite @MainActor struct ArchiveTests {
    @Test func reviewCompactionResolvesAnAcknowledgementLostAtArchiveCapacity() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        for index in 0..<128 {
            try r.audit.append(event: .denied, subject: "synthetic", payloadHash: "synthetic", actor: "synthetic", now: r.clock.time)
            client.loseNextAcknowledgement = index == 127
            do { _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store, now: r.clock.time) }
            catch { if index != 127 { throw error } }
        }
        #expect(client.blocks.count == 128); #expect(store.state.pending != nil)
        let log = try await r.audit.compact(into: MemoryJournal(), client: client, cipher: cipher, archiveStore: store)
        #expect(store.state.pending == nil); #expect(store.state.anchor.epoch == 1)
        #expect((try log.exportCheckpoint()).count == 128)
    }
    @Test func reviewByteCapacityRefusalAutomaticallyCheckpointsThePendingRecord() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        for _ in 0..<110 {
            try r.audit.append(event: .denied, subject: String(repeating: "a", count: 10_000),
                payloadHash: "synthetic", actor: "synthetic", now: r.clock.time)
            _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store, now: r.clock.time)
            if client.epoch == 1 { break }
        }
        #expect(client.epoch == 1); #expect(store.state.pending == nil); #expect(client.blocks.count == 1)
        #expect(store.state.anchor.journal.count == (try r.audit.exportCheckpoint()).count)
        _ = try await r.audit.compact(into: MemoryJournal(), client: client, cipher: cipher, archiveStore: store)
    }

    @Test func reviewAuthorityResetRejectsBadFencesAndPreservesCrashRecovery() async throws {
        for mode in ["oldSession", "fenceFailure", "fenceRace", "timeout", "partialWrite"] {
            let r = try Rig(), destination = MemoryJournal(), cp = TestCheckpoint()
            _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
            r.journal.bytes.removeLast(10)
            let fresh = r.phone.session(account: r.session.account, actor: r.session.actor, session: "fresh-fenced-session",
                device: r.session.device, project: r.session.project, destinationKind: .software)
            let fence = FixtureAuthorityFence(fresh), damaged = r.journal.bytes
            fence.handler = {
                if mode == "fenceFailure" { throw PolicyError.auditUnavailable }
                if mode == "fenceRace" { r.journal.bytes.append(10) }
                if mode == "timeout" { r.clock.time += 30_000 }
                return mode == "oldSession" ? r.session : fresh
            }
            destination.partial = mode == "partialWrite"
            do { _ = try await AuditLog.startNewAuthority(sourceJournal: r.journal, sourceCheckpoints: r.checkpoint,
                destinationJournal: destination, destinationCheckpoints: cp, retention: AuditRetention(),
                session: r.session, biometric: r.biometric, fence: fence, clock: { r.clock.time }); Issue.record("Unsafe new authority") } catch { }
            #expect(r.journal.bytes == (mode == "fenceRace" ? damaged + Data([10]) : damaged))
            #expect(r.checkpoint.value.retired == true)
            if mode == "partialWrite" {
                #expect(cp.pending != nil); destination.partial = false
                let repaired = try await AuditLog.recover(journal: destination, checkpoints: cp, retention: AuditRetention(),
                    session: fresh, biometric: r.biometric, clock: { r.clock.time })
                #expect(repaired.records.first?.event == .authorityReset)
                #expect(repaired.records.last?.event == .recovered)
            } else { #expect(destination.bytes.isEmpty); #expect(cp.value == .empty); #expect(cp.pending == nil) }
        }
    }
    @Test func reviewUnreplicatedDamageNeedsExplicitBiometricNewAuthorityAndFreshSession() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        try await replicate(r, client, cipher, store)
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        r.journal.bytes.removeLast(20)
        let damaged = r.journal.bytes, destination = MemoryJournal(), cp = TestCheckpoint()
        let fresh = r.phone.session(account: r.session.account, actor: r.session.actor, session: "new-authority-session",
            device: r.session.device, project: r.session.project, destinationKind: .software)
        let fence = FixtureAuthorityFence(fresh)
        r.biometric.handler = { _ in throw PolicyError.invalid }
        do { _ = try await AuditLog.startNewAuthority(sourceJournal: r.journal, sourceCheckpoints: r.checkpoint,
            destinationJournal: destination, destinationCheckpoints: cp, retention: AuditRetention(),
            session: r.session, biometric: r.biometric, fence: fence, clock: { r.clock.time }); Issue.record("No biometric") } catch { }
        #expect(fence.calls == 0); #expect(destination.bytes.isEmpty); #expect(r.journal.bytes == damaged)
        r.biometric.handler = nil
        let (log, newSession) = try await AuditLog.startNewAuthority(sourceJournal: r.journal, sourceCheckpoints: r.checkpoint,
            destinationJournal: destination, destinationCheckpoints: cp, retention: AuditRetention(),
            session: r.session, biometric: r.biometric, fence: fence, clock: { r.clock.time })
        #expect(r.journal.bytes == damaged); #expect(r.checkpoint.value.retired == true)
        #expect(log.records.first?.event == .authorityReset); #expect(cp.value.authorityID != nil)
        let gate = try PolicyGate(audit: log, biometric: r.biometric, clock: { r.clock.time })
        #expect(isDenied(gate.submit(try ProtocolCodec.encode(r.select()), input: r.input())))
        let preview = try requirePreview(gate.submit(ProtocolCodec.encode(r.select()), input: r.input(session: newSession)))
        let permit = try requirePermit(await gate.approve(requestID: preview.requestID,
            evidence: r.phone.approval(session: newSession, requestID: preview.requestID, payloadHash: preview.payloadHash)))
        #expect(permit.command.policy_version.contains(try #require(cp.value.authorityID)))
        _ = try await AuditArchive.rollover(log: log, client: client, cipher: cipher, store: store)
        #expect(store.state.anchor.journal.authorityID == cp.value.authorityID)
        #expect(try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: store.state.anchor, against: cp.value).isEmpty == false)
    }

    @Test func reviewUnrelatedEmptyLogCannotPruneAnExistingArchive() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        try await replicate(r, client, cipher, store)
        let original = client.blocks, state = store.state
        let unrelated = try AuditLog(journal: MemoryJournal(), checkpoints: TestCheckpoint(), retention: AuditRetention())
        do { _ = try await AuditArchive.rollover(log: unrelated, client: client, cipher: cipher, store: store); Issue.record("Unrelated journal pruned trusted archive") } catch { }
        #expect(client.blocks == original); #expect(store.state == state)
    }
    @Test func reviewFullArchiveRollsOverPendingWritesAndRetainsReplayOnRecovery() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        let input = r.input(), p = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: input))
        _ = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(p)))
        for index in 0..<128 {
            if index > 0 { try r.audit.append(event: .denied, subject: "synthetic", payloadHash: "synthetic", actor: "synthetic", now: r.clock.time) }
            _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store, now: r.clock.time)
        }
        #expect(client.blocks.count == 128)
        try r.audit.append(event: .denied, subject: "pending-after-full", payloadHash: "synthetic", actor: "synthetic", now: r.clock.time)
        client.loseNextAcknowledgement = true
        do { _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store, now: r.clock.time); Issue.record("Lost rollover acknowledgement") } catch { }
        #expect(store.state.pending?.isCheckpoint == true)
        _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store, now: r.clock.time)
        #expect(store.state.pending == nil); #expect(store.state.anchor.epoch == 1); #expect(client.blocks.count == 1)
        let compacted = try await r.audit.compact(into: MemoryJournal(), client: client, cipher: cipher, archiveStore: store)
        #expect(compacted.records.contains { $0.event == .queued })
        let destination = MemoryJournal(), cp = TestCheckpoint()
        let recovered = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
            sourceJournal: compacted.journal, sourceCheckpoints: r.checkpoint, destinationJournal: destination,
            destinationCheckpoints: cp, retention: AuditRetention(), session: r.session, biometric: r.biometric, clock: { r.clock.time })
        let gate = try PolicyGate(audit: recovered, biometric: r.biometric, clock: { r.clock.time })
        guard case .duplicate = gate.submit(try ProtocolCodec.encode(r.select()), input: input) else { Issue.record("Rollover lost replay protection"); return }
    }

    @Test func reviewWriterMismatchAndScheduledLossAreDurableAndVisible() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        client.refuseWriter = true
        do { _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store, now: r.clock.time); Issue.record("Writer mismatch accepted") }
        catch AuditArchiveFailure.writerMismatch {} catch { Issue.record("Unexpected error") }
        #expect(store.state.health == .writerMismatch); #expect(store.state.pending != nil)
        client.refuseWriter = false
        _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store, now: r.clock.time)
        client.blocks.removeAll()
        do { try await AuditArchive.verifyScheduled(client: client, cipher: cipher, store: store, now: r.clock.time + AuditArchive.verificationInterval); Issue.record("Scheduled loss hidden") }
        catch AuditArchiveFailure.lostCopy {} catch { Issue.record("Unexpected error") }
        #expect(store.state.health == .lostCopy)
    }
    @Test func reviewPaddingHidesDifferentSingleRecordLengths() async throws {
        let cipher = FixtureArchiveCipher()
        var sizes: [Int] = []
        for subject in ["a", String(repeating: "a", count: 180)] {
            let journal = MemoryJournal(), cp = TestCheckpoint()
            let log = try AuditLog(journal: journal, checkpoints: cp, retention: AuditRetention())
            try log.append(event: .denied, subject: subject, payloadHash: "synthetic", actor: "synthetic", now: 1)
            let client = FakeAuditArchiveClient(), store = ArchiveStore()
            _ = try await AuditArchive.replicate(log: log, client: client, cipher: cipher, store: store)
            sizes.append(try #require(client.blocks.first).ciphertext.count)
        }
        #expect(sizes[0] == sizes[1])
    }
    @Test func reviewAcknowledgedButMissingCopyIsSurfaced() async throws {
        let r = try Rig(), store = ArchiveStore(), cipher = FixtureArchiveCipher(), client = VanishingArchiveClient()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        do { _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store); Issue.record("Lost off-device copy treated as durable") } catch { }
        #expect(client.reads > 0)
    }
    func replicate(_ r: Rig, _ client: FakeAuditArchiveClient, _ cipher: FixtureArchiveCipher, _ store: ArchiveStore) async throws {
        while store.state.anchor.journal.count < (try r.audit.exportCheckpoint()).count {
            _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store)
        }
    }

    @Test func archiveLostAckRetriesExactBytesEvenAfterNewLocalEvents() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        client.loseNextAcknowledgement = true
        do { _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store); Issue.record("lost ack accepted") } catch { }
        let sealed = try #require(store.state.pending?.block)
        #expect(client.blocks == [sealed])
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        _ = try await AuditArchive.replicate(log: r.audit, client: client, cipher: cipher, store: store)
        #expect(client.blocks == [sealed]); #expect(store.state.pending == nil)
        try await replicate(r, client, cipher, store)
        let restored = try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: store.state.anchor, against: r.checkpoint.value)
        #expect(restored == r.journal.bytes)
        #expect(!String(decoding: try ProtocolCodec.encode(sealed), as: UTF8.self).contains("suggested"))
        #expect(try AuditArchive.hash(AuditArchiveBlock(account_id: "fixture-account", room_id: "fixture-room", sequence: 0,
            previous_hash: String(repeating: "0", count: 64), ciphertext: String(repeating: "A", count: 40), block_hash: String(repeating: "1", count: 64))) == "45fdc0c74c2ced2c088eeb7ee4bfe845a798c3a98b736044af8e376dc2e41477")
    }

    @Test func corruptTruncatedReorderedMissingWrongTenantAndKeyFailWithoutMutatingHistory() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        for _ in 0..<3 {
            _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
            try await replicate(r, client, cipher, store)
        }
        let good = client.blocks, original = r.journal.bytes, checkpoint = r.checkpoint.value
        for mode in ["corrupt", "truncate", "reorder", "missing", "tenant", "key", "inner"] {
            client.blocks = good; cipher.fail = mode == "key"
            if mode == "truncate" { client.blocks.removeLast() }
            if mode == "missing" { client.blocks.remove(at: 1) }
            if mode == "reorder" { client.blocks.swapAt(0, 1) }
            if ["corrupt", "tenant", "inner"].contains(mode) {
                let b = good[0]
                let wrong = AuditArchiveBlock(account_id: mode == "tenant" ? "other" : b.account_id,
                    room_id: b.room_id, sequence: b.sequence, previous_hash: b.previous_hash,
                    ciphertext: mode == "inner" ? try cipher.seal(AuditArchive.pad(Data("SYNTHETIC-INVALID-RECORD\n".utf8)), context: AuditArchive.context(account: b.account_id, room: b.room_id, sequence: b.sequence, previous: b.previous_hash)).base64EncodedString() : String(b.ciphertext.dropLast(4)) + "AAAA",
                    block_hash: b.block_hash)
                client.blocks[0] = AuditArchiveBlock(account_id: wrong.account_id, room_id: wrong.room_id,
                    sequence: wrong.sequence, previous_hash: wrong.previous_hash, ciphertext: wrong.ciphertext,
                    block_hash: try AuditArchive.hash(wrong))
            }
            do {
                _ = try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: store.state.anchor, against: checkpoint)
                Issue.record("Accepted archive mutation: \(mode)")
            } catch { }
            #expect(r.journal.bytes == original); #expect(r.checkpoint.value == checkpoint)
        }
    }

    @Test func authenticatedArchiveRecoveryPreservesDamagedSourceAndReplayHistory() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore(), input = r.input()
        let p = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: input))
        _ = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(p)))
        try await replicate(r, client, cipher, store)
        r.journal.bytes.removeLast(30)
        let damaged = r.journal.bytes, oldCheckpoint = r.checkpoint.value
        let restored = MemoryJournal(), newCheckpoint = TestCheckpoint()
        let log = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
            sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: restored,
            destinationCheckpoints: newCheckpoint, retention: AuditRetention(), session: r.session,
            biometric: r.biometric, clock: { r.clock.time })
        #expect(r.journal.bytes == damaged)
        #expect(r.checkpoint.value.count == oldCheckpoint.count); #expect(r.checkpoint.value.head == oldCheckpoint.head)
        #expect(log.records.last?.event == .recovered)
        let gate = try PolicyGate(audit: log, biometric: r.biometric, clock: { r.clock.time })
        guard case .duplicate = gate.submit(try ProtocolCodec.encode(r.select()), input: input) else { Issue.record("Recovery replay"); return }
    }

    @Test func archiveRecoveryRetiresOldAuthorityEvenWhenOriginalJournalWasHealthy() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        try await replicate(r, client, cipher, store)
        _ = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
            sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: MemoryJournal(),
            destinationCheckpoints: TestCheckpoint(), retention: AuditRetention(), session: r.session,
            biometric: r.biometric, clock: { r.clock.time })
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input()), .auditUnavailable))
        #expect(throws: (any Error).self) { try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention()) }
        do {
            _ = try await AuditLog.recover(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention(),
                session: r.session, biometric: r.biometric, clock: { r.clock.time })
            Issue.record("Retired authority resurrected")
        } catch { }
        do {
            _ = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
                sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: MemoryJournal(),
                destinationCheckpoints: TestCheckpoint(), retention: AuditRetention(), session: r.session,
                biometric: r.biometric, clock: { r.clock.time })
            Issue.record("Retired source created another replay domain")
        } catch { }
    }

    @Test func interruptedRetirementCanRetryOnlyTheBoundDestinationSlot() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        try await replicate(r, client, cipher, store)
        let destination = MemoryJournal(), fresh = TestCheckpoint()
        fresh.failPending = true
        do {
            _ = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
                sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: destination,
                destinationCheckpoints: fresh, retention: AuditRetention(), session: r.session,
                biometric: r.biometric, clock: { r.clock.time })
            Issue.record("Failed destination intent")
        } catch { }
        #expect(r.checkpoint.value.retired == true); #expect(r.checkpoint.value.recoveryTarget == fresh.recoverySlotID)
        #expect(fresh.value == .empty); #expect(fresh.pending == nil)
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input()), .auditUnavailable))
        fresh.failPending = false
        let restored = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
            sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: destination,
            destinationCheckpoints: fresh, retention: AuditRetention(), session: r.session,
            biometric: r.biometric, clock: { r.clock.time })
        #expect(restored.records.last?.event == .recovered)
    }

    @Test func compactionPreservesTombstonesCancellationScopeClockAndArchiveHistory() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        let input = r.input(), dismissed = r.input(), grant = r.grant()
        #expect(r.gate.installGrant(grant))
        let p = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: input))
        let permit = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(p)))
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: dismissed))
        #expect(r.gate.transition(requestID: dismissed.requestID, to: .dismissed))
        #expect(r.gate.revokeGrant(grant.id, session: r.session))
        let revoked = r.phone.session(account: r.session.account, actor: r.session.actor, session: "revoked-session",
            device: r.session.device, project: r.session.project, destinationKind: .software)
        #expect(r.gate.revokeSession(revoked))
        for _ in 0..<25 { _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input())) }
        try await replicate(r, client, cipher, store)
        let full = r.journal.bytes, destination = MemoryJournal()
        let compacted = try await r.audit.compact(into: destination, client: client, cipher: cipher, archiveStore: store)
        #expect(destination.bytes.count < full.count); #expect(r.journal.bytes == full)
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input()), .auditUnavailable))
        let restarted = try AuditLog(journal: destination, checkpoints: r.checkpoint, retention: AuditRetention())
        let gate = try PolicyGate(audit: restarted, biometric: r.biometric, clock: { r.clock.time })
        guard case .duplicate = gate.submit(try ProtocolCodec.encode(r.select()), input: input) else { Issue.record("Compaction replay"); return }
        #expect(isDenied(gate.submit(try ProtocolCodec.encode(r.select()), input: dismissed)))
        #expect(!gate.installGrant(grant))
        #expect(isDenied(gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(session: revoked))))
        let cancel = ToolCall.cancelTaskTool(CancelTaskTool(account_id: r.session.account, command_id: permit.command.command_id))
        _ = try requirePreview(gate.submit(ProtocolCodec.encode(cancel), input: r.input()))
        // Archive continues the original sequence/hash chain after local compaction.
        while store.state.anchor.journal.count < (try restarted.exportCheckpoint()).count {
            _ = try await AuditArchive.replicate(log: restarted, client: client, cipher: cipher, store: store)
        }
        let history = try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: store.state.anchor, against: r.checkpoint.value)
        #expect(history.starts(with: full)); #expect(compacted.records.count < 10)
        destination.bytes[20] ^= 1
        #expect(throws: (any Error).self) { try AuditLog(journal: destination, checkpoints: r.checkpoint, retention: AuditRetention()) }
    }

    @Test func failedCompactionAndFailedRecoveryLeaveSourcesAndAnchorsUntouched() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        let original = r.journal.bytes, checkpoint = r.checkpoint.value
        do { _ = try await r.audit.compact(into: MemoryJournal(), client: client, cipher: cipher, archiveStore: store); Issue.record("Unreplicated compaction") } catch { }
        try await replicate(r, client, cipher, store)
        r.biometric.handler = { _ in throw PolicyError.invalid }
        let destination = MemoryJournal(), fresh = TestCheckpoint()
        do {
            _ = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
                sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: destination,
                destinationCheckpoints: fresh, retention: AuditRetention(), session: r.session,
                biometric: r.biometric, clock: { r.clock.time })
            Issue.record("Failed biometric accepted")
        } catch { }
        #expect(destination.bytes.isEmpty); #expect(fresh.value == .empty)
        #expect(r.journal.bytes == original); #expect(r.checkpoint.value == checkpoint)
    }

    @Test func selfConsistentOuterArchiveStillRequiresCanonicalInnerChainAndTrustedJournalHead() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        for plaintext in [Data("SYNTHETIC-NOT-A-RECORD\n".utf8), Data(r.journal.bytes.dropLast()), Data()] {
            let aad = try AuditArchive.context(account: r.session.account, room: "fixture-room", sequence: 0, previous: AuditCheckpoint.empty.head)
            let bytes = try cipher.seal(AuditArchive.pad(plaintext), context: aad)
            let unsigned = AuditArchiveBlock(account_id: r.session.account, room_id: "fixture-room", sequence: 0,
                previous_hash: AuditCheckpoint.empty.head, ciphertext: bytes.base64EncodedString(), block_hash: AuditCheckpoint.empty.head)
            let hash = try AuditArchive.hash(unsigned)
            client.blocks = [AuditArchiveBlock(account_id: unsigned.account_id, room_id: unsigned.room_id, sequence: 0,
                previous_hash: unsigned.previous_hash, ciphertext: unsigned.ciphertext, block_hash: hash)]
            let anchor = AuditArchiveAnchor(account: r.session.account, room: "fixture-room", count: 1, head: hash, journal: r.checkpoint.value)
            do { _ = try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: anchor, against: r.checkpoint.value); Issue.record("Invalid inner chain") } catch { }
        }
        // Genuine older archive must also fail against the current independent head.
        client.blocks = []; try await replicate(r, client, cipher, store)
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        do { _ = try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: store.state.anchor, against: r.checkpoint.value); Issue.record("Old valid prefix") } catch { }
    }

    @Test func recoveryRejectsCorruptionAndSuspensionRaceBeforeWritingDestination() async throws {
        for mode in ["corrupt", "sourceRace", "checkpointRace", "destinationRace", "archiveRace", "timeout", "credential"] {
            let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
            _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
            try await replicate(r, client, cipher, store)
            let destination = MemoryJournal(), fresh = TestCheckpoint(), original = r.journal.bytes, checkpoint = r.checkpoint.value
            if mode == "corrupt" { client.blocks.removeAll() }
            r.biometric.handler = { challenge in
                if mode == "sourceRace" { r.journal.bytes.append(10) }
                if mode == "checkpointRace" { r.checkpoint.value = .empty }
                if mode == "destinationRace" { destination.bytes.append(10) }
                if mode == "archiveRace" { store.state = AuditArchiveState(anchor: AuditArchiveAnchor(account: "other", room: "other")) }
                if mode == "timeout" { r.clock.time = challenge.expiresAt }
                return AuthenticationResult(challenge: challenge, credential: mode == "credential" ? .scoped_grant : .biometric, authenticatedAt: r.clock.time)
            }
            do {
                _ = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
                    sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: destination,
                    destinationCheckpoints: fresh, retention: AuditRetention(), session: r.session,
                    biometric: r.biometric, clock: { r.clock.time })
                Issue.record("Unsafe recovery: \(mode)")
            } catch { }
            #expect(fresh.value == .empty); #expect(fresh.pending == nil)
            #expect(destination.bytes == (mode == "destinationRace" ? Data([10]) : Data()))
            #expect(r.journal.bytes == (mode == "sourceRace" ? original + Data([10]) : original))
            #expect(r.checkpoint.value == (mode == "checkpointRace" ? .empty : checkpoint))
        }
    }

    @Test func crashDuringArchiveRecoveryCanCompleteDurableIntentWithoutLosingHistory() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        try await replicate(r, client, cipher, store)
        let destination = MemoryJournal(), fresh = TestCheckpoint()
        destination.partial = true
        do {
            _ = try await AuditLog.recoverArchive(client: client, cipher: cipher, archiveStore: store,
                sourceJournal: r.journal, sourceCheckpoints: r.checkpoint, destinationJournal: destination,
                destinationCheckpoints: fresh, retention: AuditRetention(), session: r.session,
                biometric: r.biometric, clock: { r.clock.time })
            Issue.record("Partial write accepted")
        } catch { }
        #expect(fresh.pending != nil)
        #expect(throws: (any Error).self) { try AuditLog(journal: destination, checkpoints: fresh, retention: AuditRetention()) }
        destination.partial = false
        let recovered = try await AuditLog.recover(journal: destination, checkpoints: fresh, retention: AuditRetention(),
            session: r.session, biometric: r.biometric, clock: { r.clock.time })
        #expect(destination.bytes.starts(with: r.journal.bytes))
        #expect(recovered.records.filter { $0.event == .recovered }.count == 2)
    }

    @Test func compactedJournalSurvivesClockEpochRecoveryPendingWriteAndFailedCompaction() async throws {
        let r = try Rig(), client = FakeAuditArchiveClient(), cipher = FixtureArchiveCipher(), store = ArchiveStore()
        #expect(r.gate.installGrant(r.grant()))
        _ = try requirePermit(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input(.ptt)))
        try await replicate(r, client, cipher, store)
        let destination = MemoryJournal()
        r.checkpoint.fail = true
        do { _ = try await r.audit.compact(into: destination, client: client, cipher: cipher, archiveStore: store); Issue.record("Failed checkpoint") } catch { }
        r.checkpoint.fail = false
        _ = try r.audit.exportCheckpoint() // Original still healthy; orphan new file was never selected.
        let selected = MemoryJournal()
        let log = try await r.audit.compact(into: selected, client: client, cipher: cipher, archiveStore: store)
        selected.partial = true
        do { try log.append(event: .denied, subject: "synthetic", payloadHash: "synthetic", actor: "synthetic", now: r.clock.time); Issue.record("Partial append") } catch { }
        selected.partial = false; r.clock.time -= 500
        let recovered = try await AuditLog.recover(journal: selected, checkpoints: r.checkpoint, retention: AuditRetention(),
            session: r.session, biometric: r.biometric, clock: { r.clock.time })
        try recovered.append(event: .denied, subject: "synthetic", payloadHash: "synthetic", actor: "synthetic", now: r.clock.time)
        #expect(recovered.records.contains { $0.event == .queued })
        #expect(try recovered.minimumTime() == r.clock.time)
    }

    @Test func localJournalCapDeniesWithoutEviction() throws {
        let checkpoint = TestCheckpoint(), journal = MemoryJournal()
        let record = try AuditLog.makeRecord(event: .queued, subject: String(repeating: "a", count: 1_048_576),
            payloadHash: "synthetic", actor: "synthetic", now: 1000, checkpoint: .empty)
        journal.bytes = try canonical(record); journal.bytes.append(10)
        checkpoint.value = AuditCheckpoint(count: 1, head: record.recordHash)
        let log = try AuditLog(journal: journal, checkpoints: checkpoint, retention: AuditRetention())
        let huge = String(repeating: "a", count: AuditLog.maximumJournalBytes)
        let before = journal.bytes, trusted = checkpoint.value
        #expect(throws: (any Error).self) { try log.append(event: .denied, subject: huge, payloadHash: "synthetic", actor: "synthetic", now: 1000) }
        #expect(journal.bytes == before); #expect(checkpoint.value == trusted); #expect(checkpoint.pending == nil)
        #expect(throws: (any Error).self) { try AuditLog.verify(Data(repeating: 0, count: AuditLog.maximumJournalBytes + 1), against: .empty) }
    }

    @Test func tombstoneCapacityNeverCompactsAwayReplayReservations() async throws {
        let journal = MemoryJournal(), checkpoint = TestCheckpoint(), client = FakeAuditArchiveClient()
        let cipher = FixtureArchiveCipher(), store = ArchiveStore()
        var head = AuditCheckpoint.empty, bytes = Data(), batches: [Data] = [], batch = Data()
        while bytes.count < 1_060_000 {
            let record = try AuditLog.makeRecord(event: .queued, subject: PayloadDigest.sha256(Data("synthetic-\(head.count)".utf8)),
                payloadHash: String(repeating: "1", count: 64), actor: "synthetic", now: Int64(1000 + head.count),
                checkpoint: head, scopeHash: String(repeating: "2", count: 64))
            var line = try canonical(record); line.append(10)
            if batch.count + line.count > 24_000 { batches.append(batch); batch = Data() }
            batch.append(line); bytes.append(line)
            head = AuditCheckpoint(count: head.count + 1, head: record.recordHash)
        }
        batches.append(batch)
        journal.bytes = bytes; checkpoint.value = head
        let log = try AuditLog(journal: journal, checkpoints: checkpoint, retention: AuditRetention())
        var previous = AuditCheckpoint.empty.head
        for (sequence, batch) in batches.enumerated() {
            let aad = try AuditArchive.context(account: "test-account", room: "fixture-room", sequence: Int64(sequence), previous: previous)
            let unsigned = AuditArchiveBlock(account_id: "test-account", room_id: "fixture-room", sequence: Int64(sequence),
                previous_hash: previous, ciphertext: try cipher.seal(AuditArchive.pad(batch), context: aad).base64EncodedString(), block_hash: AuditCheckpoint.empty.head)
            let hash = try AuditArchive.hash(unsigned)
            client.blocks.append(AuditArchiveBlock(account_id: unsigned.account_id, room_id: unsigned.room_id, sequence: unsigned.sequence,
                previous_hash: previous, ciphertext: unsigned.ciphertext, block_hash: hash))
            previous = hash
        }
        store.state = AuditArchiveState(anchor: AuditArchiveAnchor(account: "test-account", room: "fixture-room",
            count: Int64(batches.count), head: previous, journal: head))
        #expect(try await AuditArchive.verifiedBytes(client: client, cipher: cipher, anchor: store.state.anchor, against: head) == bytes)
        let destination = MemoryJournal()
        do {
            _ = try await log.compact(into: destination, client: client, cipher: cipher, archiveStore: store)
            Issue.record("Replay eviction at capacity")
        } catch PolicyError.auditUnavailable { } catch { Issue.record("Unexpected compaction error: \(error)") }
        #expect(destination.bytes.isEmpty); #expect(journal.bytes == bytes)
        #expect(try log.exportCheckpoint() == head); #expect(checkpoint.pending == nil)
        #expect(log.records.allSatisfy { $0.event == .queued })
    }
}
