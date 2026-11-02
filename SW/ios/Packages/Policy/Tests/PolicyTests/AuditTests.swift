import Foundation
import Testing
import TrustedInput
import VoiceRemoteProtocol
@testable import Policy

@Suite @MainActor struct GateAuditTests {
    @Test func sha256KnownAnswersAndPaddingBoundaries() {
        #expect(PayloadDigest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(PayloadDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(PayloadDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(PayloadDigest.sha256(Data(repeating: 0x61, count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func chainDetectsEditRemovalReorderAndTailTruncation() throws {
        let r = try Rig()
        for _ in 0..<4 { _ = r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input()) }
        let original = r.journal.bytes
        #expect(try AuditLog.verify(original, against: r.checkpoint.value) == r.audit.records)
        let lines = original.split(separator: UInt8(10)).map { Data($0) }
        func join(_ lines: [Data]) -> Data {
            var result = Data()
            for line in lines { result.append(line); result.append(10) }
            return result
        }
        var edited = lines
        var object = try #require(JSONSerialization.jsonObject(with: edited[1]) as? [String: Any])
        object["event"] = "queued"
        edited[1] = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        var reordered = lines; reordered.swapAt(1, 2)
        var removed = lines; removed.remove(at: 1)
        for bytes in [join(edited), join(reordered), join(removed), join(Array(lines.dropLast())), Data(), original.dropLast()] {
            #expect(throws: (any Error).self) { try AuditLog.verify(bytes, against: r.checkpoint.value) }
        }
        // A self-consistent old prefix is still rejected against the independent head.
        let old = AuditCheckpoint(count: 1, head: r.audit.records[0].recordHash)
        #expect(try AuditLog.verify(join([lines[0]]), against: old).count == 1)
        #expect(throws: (any Error).self) { try AuditLog.verify(original, against: old) }
    }

    @Test func extraFieldsDuplicateKeysAndWhitespaceAreTampering() throws {
        let r = try Rig()
        _ = r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input())
        let line = String(decoding: r.journal.bytes, as: UTF8.self)
        for suffix in [",\"unexpected\":\"synthetic\"}", ",\"event\":\"suggested\"}", " }"] {
            let changed = String(line.dropLast(2)) + suffix + "\n"
            #expect(throws: (any Error).self) { try AuditLog.verify(Data(changed.utf8), against: r.checkpoint.value) }
        }
    }

    @Test func replacedOpenJournalFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("audit.jsonl")
        let journal = try FileAuditJournal(url: path)
        try FileManager.default.moveItem(at: path, to: directory.appendingPathComponent("replaced.jsonl"))
        #expect(throws: (any Error).self) { try journal.read() }
        #expect(throws: (any Error).self) { try journal.append(Data("synthetic".utf8)) }
    }

    @Test func auditContainsOnlyHashesAndFixedMetadataAndRetentionNeverErasesReplay() async throws {
        let r = try Rig(), input = r.input()
        let preview = try requirePreview(r.gate.submit(try r.candidate(r.send("UNIQUE_SYNTHETIC_CONTENT_MARKER")), input: input))
        _ = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview)))
        let bytesBefore = r.journal.bytes
        let encoded = String(decoding: bytesBefore, as: UTF8.self)
        for value in ["UNIQUE_SYNTHETIC_CONTENT_MARKER", "fixture-recipient", r.session.account,
                      r.session.actor, r.session.project, r.session.device, r.session.session] {
            #expect(!encoded.contains(value))
        }
        #expect(r.audit.recordsDueForArchival(at: r.clock.time + 999).isEmpty)
        #expect(r.audit.recordsDueForArchival(at: r.clock.time + 1000).count == r.audit.records.count)
        #expect(r.journal.bytes == bytesBefore)
        #expect(throws: (any Error).self) { try AuditRetention(archiveAfterMilliseconds: 0) }
    }

    @Test func fileJournalReopensAndExcludesSecondWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("audit.jsonl")
        let anchor = TestCheckpoint()
        let clock = TestClock(), phone = PhoneInput(now: { 1_000_000 })
        let bio = FakeBiometric(clock)
        let session = phone.session(account: "a", actor: "u", session: "s", device: "d", project: "p", destinationKind: .software)
        let input = phone.activation(session: session, kind: .inferred, expiresAt: 1_100_000)
        let data = try ProtocolCodec.encode(ToolCall.selectTargetTool(SelectTargetTool(account_id: "a", device_id: "d")))
        do {
            let journal = try FileAuditJournal(url: path)
            #expect(throws: (any Error).self) { try FileAuditJournal(url: path) }
            let log = try AuditLog(journal: journal, checkpoints: anchor, retention: AuditRetention())
            let gate = try PolicyGate(audit: log, biometric: bio, clock: { clock.time })
            #expect(throws: (any Error).self) { try PolicyGate(audit: log, biometric: bio) }
            let preview = try requirePreview(gate.submit(data, input: input))
            _ = try requirePermit(await gate.approve(requestID: input.requestID,
                evidence: phone.approval(session: session, requestID: input.requestID, payloadHash: preview.payloadHash)))
        }
        let reopened = try FileAuditJournal(url: path)
        let recovered = try AuditLog(journal: reopened, checkpoints: anchor, retention: AuditRetention())
        let gate = try PolicyGate(audit: recovered, biometric: bio, clock: { clock.time })
        guard case .duplicate = gate.submit(data, input: input) else { Issue.record("File replay escaped"); return }
        #expect(recovered.records.filter { $0.event == .queued }.count == 1)
    }

    @Test func queuedReservationCheckpointFailureDeniesAndBlocksRestart() async throws {
        let r = try Rig(), input = r.input()
        let preview = try requirePreview(r.gate.submit(try ProtocolCodec.encode(r.select()), input: input))
        // Suggestion is count 1, approval is 2, and the durable reservation is 3.
        r.checkpoint.failAtCount = 3
        #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview)), .auditUnavailable))
        #expect(String(decoding: r.journal.bytes, as: UTF8.self).contains("\"event\":\"queued\""))
        #expect(r.checkpoint.value.count == 2)
        #expect(throws: (any Error).self) {
            try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention())
        }
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: input), .auditUnavailable))
    }

    @Test func interruptedWriteOrCheckpointCannotBeSilentlyRecovered() throws {
        let r = try Rig()
        _ = r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input())
        r.journal.partial = true
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input()), .auditUnavailable))
        #expect(throws: (any Error).self) {
            try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention())
        }
        let other = try Rig()
        other.checkpoint.fail = true
        #expect(isDenied(other.gate.submit(try ProtocolCodec.encode(other.select()), input: other.input()), .auditUnavailable))
        other.checkpoint.fail = false
        #expect(throws: (any Error).self) {
            try AuditLog(journal: other.journal, checkpoints: other.checkpoint, retention: AuditRetention())
        }
    }
}
