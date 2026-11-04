import Foundation
import Testing
import TrustedInput
import VoiceRemoteProtocol
@testable import Policy

@Suite @MainActor struct GateRecoveryTests {
    func recover(_ r: Rig) async throws -> AuditLog {
        try await AuditLog.recover(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention(),
                                   session: r.session, biometric: r.biometric, clock: { try r.clock.read() })
    }

    @Test func review8CrashRecoveryRequiresAuthenticationAndPreservesReservation() async throws {
        let r = try Rig(), input = r.input()
        let preview = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: input))
        r.checkpoint.failAtCount = 3
        #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview))))
        let original = r.journal.bytes
        r.checkpoint.failAtCount = nil
        let log = try await recover(r)
        #expect(r.biometric.calls.count == 1)
        #expect(r.journal.bytes.starts(with: original))
        #expect(log.records.last?.event.rawValue == "recovered")
        let gate = try PolicyGate(audit: log, biometric: r.biometric, clock: { try r.clock.read() })
        guard case .duplicate = gate.submit(try ProtocolCodec.encode(r.select()), input: input) else {
            Issue.record("Recovery lost queued reservation"); return
        }
    }

    @Test func review8FutureClockRecoveryPreservesHistoryAndAllowsFreshWork() async throws {
        let r = try Rig(), normal = r.clock.time
        r.clock.time += 86_400_000
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        let original = r.journal.bytes
        r.clock.time = normal
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input())))
        let log = try await recover(r)
        #expect(r.biometric.calls.count == 1)
        #expect(r.journal.bytes.starts(with: original))
        #expect(log.records.last?.event.rawValue == "recovered")
        #expect(log.records.last?.timestamp == normal)
        let gate = try PolicyGate(audit: log, biometric: r.biometric, clock: { try r.clock.read() })
        _ = try requirePreview(gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
        _ = try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention())
    }

    @Test func review8PartialWriteAndCrashDuringRecoveryRemainAudited() async throws {
        for initialFailure in ["beforeAppend", "partialAppend", "checkpoint"] {
            let r = try Rig()
            _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
            if initialFailure == "beforeAppend" { r.journal.fail = true }
            if initialFailure == "partialAppend" { r.journal.partial = true }
            if initialFailure == "checkpoint" { r.checkpoint.fail = true }
            #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input())))
            let damaged = r.journal.bytes
            r.journal.fail = false; r.journal.partial = false; r.checkpoint.fail = false
            // Fail recovery's final checkpoint after its event has been appended.
            r.checkpoint.failAtCount = 3
            do { _ = try await recover(r); Issue.record("Expected injected checkpoint failure") } catch { }
            #expect(r.journal.bytes.starts(with: damaged))
            #expect(throws: (any Error).self) {
                try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention())
            }
            r.checkpoint.failAtCount = nil
            let log = try await recover(r)
            #expect(log.records.filter { $0.event == .recovered }.count == 2)
            #expect(log.records.filter { $0.event == .suggested }.count == 2)
            #expect(r.biometric.calls.count == 2)
        }
    }

    @Test func review8PendingMismatchAndSnapshotRaceDenyRecovery() async throws {
        for mode in ["pendingMismatch", "race", "timeout", "credential"] {
            let r = try Rig()
            r.checkpoint.fail = true
            #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input())))
            r.checkpoint.fail = false
            if mode == "pendingMismatch" { r.journal.bytes[10] ^= 1 }
            r.biometric.handler = { challenge in
                if mode == "race" { r.journal.bytes.append(10) }
                if mode == "timeout" { r.clock.time = challenge.expiresAt }
                return AuthenticationResult(challenge: challenge,
                    credential: mode == "credential" ? .scoped_grant : .biometric, authenticatedAt: r.clock.time)
            }
            let anchor = r.checkpoint.value, intent = r.checkpoint.pending
            do { _ = try await recover(r); Issue.record("Unexpected recovery: \(mode)") } catch { }
            #expect(r.checkpoint.value == anchor)
            #expect(r.checkpoint.pending == intent)
        }
    }

    @Test func review8RecoveryCannotHideTamperingOrAcceptFailedBiometrics() async throws {
        for mode in ["edited", "removed", "extra", "failedAuth", "staleAuth", "wrongHash"] {
            let r = try Rig()
            _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input()))
            switch mode {
            case "edited": r.journal.bytes[10] ^= 1
            case "removed": r.journal.bytes = Data()
            case "extra": r.journal.bytes.append(Data("synthetic".utf8))
            case "failedAuth": r.biometric.handler = { _ in throw PolicyError.invalid }
            case "staleAuth": r.biometric.handler = { challenge in
                AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: challenge.issuedAt - 1)
            }
            default: r.biometric.handler = { challenge in
                AuthenticationResult(challenge: AuthenticationChallenge(id: challenge.id, payloadHash: "wrong",
                    issuedAt: challenge.issuedAt, expiresAt: challenge.expiresAt), credential: .biometric, authenticatedAt: r.clock.time)
            }
            }
            let before = r.journal.bytes, anchor = r.checkpoint.value
            do { _ = try await recover(r); Issue.record("Unsafe recovery succeeded: \(mode)") } catch { }
            #expect(r.journal.bytes == before)
            #expect(r.checkpoint.value == anchor)
        }
    }
}
