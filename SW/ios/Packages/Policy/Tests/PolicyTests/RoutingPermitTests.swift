import Foundation
import Testing
import TrustedInput
import VoiceRemoteProtocol
@testable import Policy

@Suite @MainActor struct RoutingPermitGateTests {
    @Test func routingPermitReverificationBindsExactCommandPreviewAndLiveApproval() async throws {
        let r = try Rig()
        let input = r.input(.inferred)
        let preview = try requirePreview(r.gate.submit(try ProtocolCodec.encode(r.fixtures()[2].1), input: input))
        let permit = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview)))
        let verified = try r.gate.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
        #expect(verified.command == permit.command)
        for field in ["destination_id", "payload_hash", "granted_scope_id"] {
            var body = try #require(JSONSerialization.jsonObject(with: ProtocolCodec.encode(permit.command)) as? [String: Any])
            body[field] = field == "payload_hash" ? String(repeating: "0", count: 64) : "forged"
            let forged = try ProtocolCodec.decode(AuthorizedCommand.self, from: JSONSerialization.data(withJSONObject: body))
            #expect(throws: (any Error).self) {
                try r.gate.verifyExecution(command: forged, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
            }
        }
        #expect(throws: (any Error).self) {
            try r.gate.verifyExecution(command: permit.command, immutablePreview: Data("forged".utf8), expiresAt: permit.expiresAt)
        }
        #expect(r.gate.revokeSession(r.session))
        #expect(throws: (any Error).self) {
            try r.gate.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
        }
        let other = try Rig()
        #expect(throws: (any Error).self) {
            try other.gate.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
        }
    }
    @Test func routingPermitExpiryAndRealGateRestartRequireReapproval() async throws {
        let r = try Rig()
        let input = r.input(.inferred)
        let preview = try requirePreview(r.gate.submit(try ProtocolCodec.encode(r.select()), input: input))
        let permit = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview)))
        let restoredAudit = try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention())
        let restoredGate = try PolicyGate(audit: restoredAudit, biometric: r.biometric, clock: { try r.clock.read() })
        #expect(throws: (any Error).self) {
            try restoredGate.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
        }
        r.clock.time = permit.expiresAt
        #expect(throws: (any Error).self) {
            try r.gate.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
        }
    }

}
