import Foundation
import Testing
import TrustedInput
import VoiceRemoteProtocol
@testable import Policy

@Suite @MainActor struct GateReviewRegressionTests {
    func reconnect(_ r: Rig, project: String? = nil) -> InputSession {
        r.phone.session(account: r.session.account, actor: r.session.actor, session: "reconnected",
                        device: r.session.device, project: project ?? r.session.project, destinationKind: .software)
    }
    func restart(_ r: Rig) throws -> PolicyGate {
        try PolicyGate(audit: AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention()),
                       biometric: r.biometric, clock: { try r.clock.read() })
    }

    @Test func review1EditsCannotLowerPreviouslyRaisedRisk() async throws {
        let r = try Rig(), input = r.input()
        _ = try requirePreview(r.gate.submit(r.candidate(r.select(), risk: .sensitive), input: input))
        let edited = try requirePreview(r.gate.edit(requestID: input.requestID, modelJSON: ProtocolCodec.encode(r.select())))
        #expect(edited.risk == .sensitive)
        _ = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(edited)))
        #expect(r.biometric.calls.count == 1)
    }

    @Test func review2GrantsHaveFiniteRiskSpecificLifetimes() throws {
        for (risk, cap): (RiskClass, Int64) in [(.read_display, 86_400_000), (.workspace_modify, 900_000)] {
            let r = try Rig()
            #expect(r.gate.installGrant(r.grant(risk: risk, expiry: r.clock.time + cap)))
            #expect(!r.gate.installGrant(r.grant(risk: risk, expiry: r.clock.time + cap + 1)))
            #expect(!r.gate.installGrant(r.grant(risk: risk, expiry: 9_007_199_254_740_991)))
        }
        let r = try Rig()
        let ancient = r.grant(expiry: r.clock.time + 86_400_001)
        r.clock.time += 10_000
        #expect(!r.gate.installGrant(ancient)) // cap measured from issuance, not installation
    }

    @Test func review3RevokedGrantIDsStayRevokedAfterRestart() throws {
        let r = try Rig(), grant = r.grant()
        #expect(r.gate.installGrant(grant))
        #expect(r.gate.revokeGrant(grant.id, session: r.session))
        #expect(!r.gate.installGrant(grant))
        let fresh = try restart(r)
        #expect(!fresh.installGrant(grant))
        #expect(isDenied(fresh.submit(try ProtocolCodec.encode(r.select()), input: r.input(.ptt))))
    }

    @Test func review4RevocationUsesScopeAndSessionIdentity() throws {
        let r = try Rig(), grant = r.grant()
        #expect(r.gate.installGrant(grant))
        #expect(!r.gate.revokeGrant(grant.id, session: reconnect(r, project: "wrong-project")))
        #expect(r.gate.revokeGrant(grant.id, session: reconnect(r)))
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.ptt, session: reconnect(r)))))
        let otherProject = r.phone.session(account: r.session.account, actor: r.session.actor, session: r.session.session,
            device: r.session.device, project: "other-project", destinationKind: .software)
        let otherGrant = r.grant(session: otherProject)
        #expect(r.gate.installGrant(otherGrant))
        #expect(r.gate.revokeSession(r.session))
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.ptt, session: reconnect(r, project: "other-project")))))
        #expect(!r.gate.installGrant(otherGrant))
    }

    @Test func review5EveryTransitionRechecksExpiryAndRevocation() throws {
        for invalidation in ["expiry", "session", "grant"] {
            for target: ProposalState in [.dispatched, .running, .succeeded] {
                let r = try Rig(), grant = r.grant(), input = r.input(.ptt)
                #expect(r.gate.installGrant(grant))
                let permit = try requirePermit(r.gate.submit(ProtocolCodec.encode(r.select()), input: input))
                if target != .dispatched { #expect(r.gate.transition(requestID: input.requestID, to: .dispatched)) }
                if target == .succeeded { #expect(r.gate.transition(requestID: input.requestID, to: .running)) }
                switch invalidation {
                case "expiry": r.clock.time = permit.expiresAt
                case "session": #expect(r.gate.revokeSession(r.session))
                default: #expect(r.gate.revokeGrant(grant.id, session: r.session))
                }
                #expect(!r.gate.transition(requestID: input.requestID, to: target))
            }
        }
    }

    @Test func review7RegistryKindMustBeExplicitAtConstruction() throws {
        // Fail before the fix: omitting registry classification currently compiles.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/TrustedInput/TrustedInput.swift"), encoding: .utf8)
        #expect(!source.contains("destinationKind: DestinationKind = .software"))
        #expect(source.contains("case unknown"))
        let r = try Rig()
        let unknown = r.phone.session(account: r.session.account, actor: r.session.actor, session: r.session.session,
            device: r.session.device, project: r.session.project, destinationKind: .unknown)
        #expect(!r.gate.installGrant(r.grant(session: unknown)))
        for kind: InputActivation in [.inferred, .ptt, .wakeWord] {
            #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(kind, session: unknown)), .hardwarePolicyMissing))
        }
    }

    @Test func review9CancelWorksAcrossReconnectAndRestart() throws {
        let r = try Rig()
        #expect(r.gate.installGrant(r.grant()))
        let original = try requirePermit(r.gate.submit(ProtocolCodec.encode(r.select()), input: r.input(.ptt)))
        let cancel = ToolCall.cancelTaskTool(CancelTaskTool(account_id: r.session.account, command_id: original.command.command_id))
        for restarted in [false, true] {
            let gate = restarted ? try restart(r) : r.gate
            let session = reconnect(r)
            #expect(isDenied(gate.submit(try ProtocolCodec.encode(cancel), input: r.input(.ptt, session: reconnect(r, project: "wrong-project"))), .contextMismatch))
            #expect(gate.installGrant(r.grant(.cancel_task, risk: .workspace_modify, session: session)))
            _ = try requirePermit(gate.submit(ProtocolCodec.encode(cancel), input: r.input(.ptt, session: session)))
        }
    }

    @Test func review10DismissalSurvivesRestartAndPayloadChange() throws {
        let r = try Rig(), input = r.input()
        _ = try requirePreview(r.gate.submit(ProtocolCodec.encode(r.select()), input: input))
        #expect(r.gate.transition(requestID: input.requestID, to: .dismissed))
        let fresh = try restart(r)
        for tool in [r.select(), r.send()] {
            #expect(isDenied(fresh.submit(try ProtocolCodec.encode(tool), input: r.input(.ptt, session: reconnect(r), id: input.requestID)), .invalidState))
        }
    }
}
