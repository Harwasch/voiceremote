import Foundation
import Testing
import TrustedInput
import VoiceRemoteProtocol
@testable import Policy

@MainActor final class TestClock {
    var time: Int64 = 1_000_000
    var broken = false
    func read() throws -> Int64 { if broken { throw PolicyError.clock }; return time }
}
@MainActor final class MemoryJournal: AuditJournal {
    var bytes = Data()
    var fail = false
    var partial = false
    func read() throws -> Data { bytes }
    func append(_ data: Data) throws {
        if partial { bytes.append(data.prefix(data.count / 2)); throw PolicyError.auditUnavailable }
        if fail { throw PolicyError.auditUnavailable }
        bytes.append(data)
    }
}
@MainActor final class TestCheckpoint: AuditCheckpointStore {
    var value = AuditCheckpoint.empty
    var fail = false
    var failAtCount: Int?
    var pending: AuditPending?
    func loadPending() throws -> AuditPending? { pending }
    func savePending(_ value: AuditPending?) throws { pending = value }
    func load() throws -> AuditCheckpoint { value }
    func save(_ checkpoint: AuditCheckpoint) throws {
        if fail || checkpoint.count == failAtCount { throw PolicyError.auditUnavailable }
        value = checkpoint
    }
}
@MainActor final class FakeBiometric: Biometric {
    var calls: [AuthenticationChallenge] = []
    var handler: ((AuthenticationChallenge) async throws -> AuthenticationResult)?
    let clock: TestClock
    init(_ clock: TestClock) { self.clock = clock }
    func authenticate(_ challenge: AuthenticationChallenge) async throws -> AuthenticationResult {
        calls.append(challenge)
        if let handler { return try await handler(challenge) }
        return AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: clock.time)
    }
}
@MainActor final class Rig {
    let clock = TestClock()
    let journal = MemoryJournal()
    let checkpoint = TestCheckpoint()
    let phone: PhoneInput
    let biometric: FakeBiometric
    let audit: AuditLog
    let gate: PolicyGate
    let session: InputSession
    init() throws {
        let clock = self.clock
        phone = PhoneInput(now: { clock.time })
        session = phone.session(account: "test-account", actor: "test-actor", session: "test-session", device: "test-device", project: "test-project", destinationKind: .software)
        biometric = FakeBiometric(clock)
        audit = try AuditLog(journal: journal, checkpoints: checkpoint, retention: AuditRetention(archiveAfterMilliseconds: 1000))
        gate = try PolicyGate(audit: audit, biometric: biometric, clock: { try clock.read() })
    }
    func input(_ kind: InputActivation = .inferred, session: InputSession? = nil,
               id: UUID = UUID(), mode: InputMode = .command, ambiguous: Bool = false,
               expiry: Int64? = nil) -> ActivationEvidence {
        phone.activation(session: session ?? self.session, requestID: id, kind: kind, mode: mode,
                         ambiguousMeetingWake: ambiguous, expiresAt: expiry ?? clock.time + 120_000)
    }
    func grant(_ capability: Capability = .receive_text, risk: RiskClass = .read_display,
               session: InputSession? = nil, expiry: Int64? = nil) -> GrantEvidence {
        phone.grant(session: session ?? self.session, capability: capability, risk: risk, expiresAt: expiry ?? clock.time + 100_000)
    }
    func approval(_ preview: Preview, session: InputSession? = nil, source: ApprovalSource = .phone) -> ApprovalEvidence {
        phone.approval(session: session ?? self.session, requestID: preview.requestID, payloadHash: preview.payloadHash, source: source)
    }
    func select() -> ToolCall {
        .selectTargetTool(SelectTargetTool(account_id: session.account, device_id: session.device))
    }
    func send(_ content: String = "synthetic fixture") -> ToolCall {
        .prepareSendTool(PrepareSendTool(account_id: session.account, device_id: session.device, recipient: "fixture-recipient", content: content))
    }
    func candidate(_ tool: ToolCall, risk: RiskClass = .read_display,
                   state: CandidateState = .approved, expiry: Int64? = nil) throws -> Data {
        try ProtocolCodec.encode(CandidateAction(account_id: session.account, candidate_id: "untrusted-candidate",
            parent_capture_session: session.session, segment_span_ids: ["synthetic-segment"],
            proposed_task_kind: .receive_text, proposed_task: tool, proposed_payload_hash: String(repeating: "0", count: 64),
            origin_confidence: 1, proposed_risk_class: risk, suggestion_expiry: expiry ?? clock.time + 120_000,
            card_visibility: .muted, candidate_state: state))
    }
    func fixtures() throws -> [(String, ToolCall, Capability, RiskClass)] {
        // Cancellation is scoped to a command actually issued in this session.
        #expect(gate.installGrant(grant()))
        let permit = try requirePermit(gate.submit(try ProtocolCodec.encode(select()), input: input(.ptt)))
        return [
            ("select_target", select(), .receive_text, .read_display),
            ("open_resource", .openResourceTool(OpenResourceTool(account_id: session.account, device_id: session.device,
                                                               resource_uri: "https://example.invalid/fixture")), .open_resource, .sensitive),
            ("delegate_task", .delegateTaskTool(DelegateTaskTool(account_id: session.account, device_id: session.device,
                                                               project_id: session.project, instruction: "synthetic fixture")), .delegate_task, .sensitive),
            ("cancel_task", .cancelTaskTool(CancelTaskTool(account_id: session.account, command_id: permit.command.command_id)), .cancel_task, .workspace_modify),
            ("prepare_send", send(), .external_send, .sensitive)
        ]
    }
}

func requirePreview(_ decision: GateDecision) throws -> Preview {
    switch decision {
    case .suggestion(let p), .authenticationRequired(let p): return p
    default: Issue.record("Expected preview, got \(decision)"); throw PolicyError.invalid
    }
}
func requirePermit(_ decision: GateDecision) throws -> ExecutionPermit {
    guard case .queued(let p) = decision else { Issue.record("Expected permit, got \(decision)"); throw PolicyError.invalid }
    return p
}
func isDenied(_ decision: GateDecision, _ reason: Denial? = nil) -> Bool {
    guard case .denied(let actual) = decision else { return false }
    return reason == nil || actual == reason
}

@Suite @MainActor struct GateTests {
    @Test func everySchemaToolEveryTierRequiresCorrectAuthority() async throws {
        let coverageRig = try Rig()
        let fixtures = try coverageRig.fixtures()
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("SYS/tools/tool-call.schema.json"))) as? [String: Any])
        let defs = try #require(schema["$defs"] as? [String: Any])
        let union = try #require(defs["ToolCall"] as? [String: Any])
        let members = try #require(union["oneOf"] as? [[String: String]])
        let names = try members.map { ref -> String in
            let name = try #require(ref["$ref"]?.split(separator: "/").last.map(String.init))
            let definition = try #require(defs[name] as? [String: Any])
            let properties = try #require(definition["properties"] as? [String: Any])
            return try #require((properties["kind"] as? [String: String])?["const"])
        }
        #expect(Set(names) == Set(fixtures.map { $0.0 }))
        for name in names {
            for tier in 1...3 {
                let r = try Rig()
                let (_, tool, capability, minimum) = try #require(r.fixtures().first { $0.0 == name })
                let input = r.input(tier == 1 ? .inferred : .ptt)
                let risk: RiskClass = tier == 3 ? .sensitive : .read_display
                let data = try r.candidate(tool, risk: risk)
                let beforeQueued = r.audit.records.filter { $0.event == .queued }.count
                let decision = r.gate.submit(data, input: input)
                if tier == 1 {
                    guard case .suggestion(let preview) = decision else { Issue.record("\(name): inferred escaped suggestion"); continue }
                    #expect(r.audit.records.filter { $0.event == .queued }.count == beforeQueued)
                    #expect(r.biometric.calls.isEmpty)
                    let permit = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview)))
                    #expect(permit.command.approval_event_id != nil)
                    #expect(permit.command.source_tier == .inferred)
                    #expect(r.biometric.calls.count == (minimum == .sensitive ? 1 : 0))
                } else if tier == 3 || minimum == .sensitive {
                    guard case .authenticationRequired(let preview) = decision else { Issue.record("\(name): sensitive action did not ask for authentication"); continue }
                    #expect(r.audit.records.filter { $0.event == .queued }.count == beforeQueued)
                    #expect(!r.gate.installGrant(r.grant(capability, risk: .sensitive)))
                    // Every tool rejects a mismatched and an expired approval.
                    let mismatch = r.phone.approval(session: r.session, requestID: input.requestID,
                        payloadHash: String(repeating: "f", count: 64))
                    #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: mismatch), .invalidApproval))
                    let stale = r.approval(preview)
                    r.clock.time += 30_000
                    #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: stale), .invalidApproval))
                    let permit = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview)))
                    #expect(r.biometric.calls.count == 1)
                    #expect(permit.command.approval_credential_class == .biometric)
                    #expect(permit.command.risk_class == .sensitive)
                    #expect(permit.command.payload_hash == PayloadDigest.sha256(permit.immutablePreview))
                    #expect(try ProtocolCodec.decode(AuthorizedCommand.self, from: ProtocolCodec.encode(permit.command)) == permit.command)
                } else {
                    // select already has a grant from fixtures; cancellation needs its own.
                    if capability == .cancel_task {
                        #expect(isDenied(decision, .missingGrant))
                        #expect(r.gate.installGrant(r.grant(capability, risk: minimum)))
                        _ = try requirePermit(r.gate.submit(data, input: input))
                    } else { _ = try requirePermit(decision) }
                    #expect(r.biometric.calls.isEmpty)
                }
            }
        }
    }

    @Test func modelAuthorityInjectionUnknownToolsAndRiskDeny() throws {
        let fields: [String: Any] = ["authenticated_actor": "forged", "activation_kind": "ptt",
            "approval_credential_class": "biometric", "granted_scope_id": "global",
            "source_tier": "explicit", "approval_event_id": "forged", "risk_class": "read_display"]
        for field in fields.keys {
            let r = try Rig()
            for nested in [false, true] {
                var object = try #require(JSONSerialization.jsonObject(with: r.candidate(r.select())) as? [String: Any])
                if nested {
                    var tool = try #require(object["proposed_task"] as? [String: Any]); tool[field] = fields[field]; object["proposed_task"] = tool
                } else { object[field] = fields[field] }
                #expect(isDenied(r.gate.submit(try JSONSerialization.data(withJSONObject: object), input: r.input(.ptt))))
            }
        }
        let r = try Rig()
        for raw in [#"{"kind":"actuate","account_id":"test-account"}"#,
                    #"{"kind":"delete","account_id":"test-account"}"#,
                    #"{"kind":"pay","account_id":"test-account"}"#,
                    #"{"kind":"select_target","account_id":"test-account","device_id":"test-device","device_id":"test-device"}"#] {
            #expect(isDenied(r.gate.submit(Data(raw.utf8), input: r.input(.ptt))))
        }
        var candidate = try #require(JSONSerialization.jsonObject(with: r.candidate(r.select())) as? [String: Any])
        candidate["proposed_risk_class"] = "unknown-risk"
        #expect(isDenied(r.gate.submit(try JSONSerialization.data(withJSONObject: candidate), input: r.input(.ptt))))
        for type: Any.Type in [ActivationEvidence.self, ApprovalEvidence.self, GrantEvidence.self, ExecutionPermit.self] {
            #expect(!(type is any Decodable.Type))
        }
        #expect(r.audit.records.allSatisfy { $0.event == .denied })
    }

    @Test func candidateStateHashAndConfidenceNeverAuthorize() throws {
        let r = try Rig()
        for state: CandidateState in [.suggested, .edited, .approved, .dismissed, .expired] {
            let input = r.input()
            let preview = try requirePreview(r.gate.submit(try r.candidate(r.select(), state: state), input: input))
            #expect(preview.state == .suggested)
            #expect(preview.payloadHash != String(repeating: "0", count: 64))
            #expect(r.gate.state(requestID: input.requestID) == .suggested)
        }
        #expect(!r.audit.records.contains { $0.event == .queued })
    }

    @Test func tierThreeRejectsStaleMismatchedAndRemoteApprovals() async throws {
        for bad in ["stale", "hash", "request", "actor", "remote"] {
            let r = try Rig(), input = r.input(.ptt)
            let preview = try requirePreview(r.gate.submit(try r.candidate(r.send()), input: input))
            let other = r.phone.session(account: r.session.account, actor: "other", session: r.session.session,
                                        device: r.session.device, project: r.session.project, destinationKind: .software)
            let evidence = r.phone.approval(session: bad == "actor" ? other : r.session,
                requestID: bad == "request" ? UUID() : input.requestID,
                payloadHash: bad == "hash" ? String(repeating: "f", count: 64) : preview.payloadHash,
                source: bad == "remote" ? .remoteButton : .phone)
            if bad == "stale" { r.clock.time += 30_000 }
            #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: evidence), .invalidApproval))
            #expect(r.biometric.calls.isEmpty)
            #expect(!r.audit.records.contains { $0.event == .queued })
        }
    }

    @Test func authenticationFailureWrongChallengeStaleResultAndPasscode() async throws {
        for mode in ["throw", "stale", "future", "hash", "challenge", "credential", "timeout", "passcode"] {
            let r = try Rig(), input = r.input(.ptt)
            let preview = try requirePreview(r.gate.submit(try r.candidate(r.send()), input: input))
            r.biometric.handler = { challenge in
                if mode == "throw" { throw PolicyError.invalid }
                if mode == "timeout" { r.clock.time = challenge.expiresAt }
                let changed = AuthenticationChallenge(id: mode == "challenge" ? UUID() : challenge.id,
                    payloadHash: mode == "hash" ? String(repeating: "f", count: 64) : challenge.payloadHash,
                    issuedAt: challenge.issuedAt, expiresAt: challenge.expiresAt)
                return AuthenticationResult(challenge: changed, credential: mode == "credential" ? .user_presence : .passcode,
                    authenticatedAt: mode == "stale" ? challenge.issuedAt - 1 : (mode == "future" ? r.clock.time + 1 : r.clock.time))
            }
            let decision = await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview))
            #expect(r.biometric.calls.count == 1)
            if mode == "passcode" { #expect(try requirePermit(decision).command.approval_credential_class == .passcode) }
            else { #expect(isDenied(decision, .authenticationFailed)) }
        }
    }

    @Test func editingInvalidatesApprovalIncludingABAAndDuringAuthentication() async throws {
        let r = try Rig(), input = r.input()
        let first = try requirePreview(r.gate.submit(try r.candidate(r.send()), input: input))
        let oldApproval = r.approval(first)
        let changed = try requirePreview(r.gate.edit(requestID: input.requestID, modelJSON: r.candidate(r.send("changed synthetic fixture"))))
        #expect(changed.state == .edited)
        #expect(changed.payloadHash != first.payloadHash)
        #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: oldApproval), .invalidApproval))
        let restored = try requirePreview(r.gate.edit(requestID: input.requestID, modelJSON: r.candidate(r.send())))
        #expect(restored.payloadHash != first.payloadHash)
        #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: oldApproval), .invalidApproval))
        r.biometric.handler = { challenge in
            _ = r.gate.edit(requestID: input.requestID, modelJSON: try r.candidate(r.send("third synthetic fixture")))
            return AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: r.clock.time)
        }
        #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: r.approval(restored)), .authenticationFailed))
        #expect(!r.audit.records.contains { $0.event == .queued })
    }

    @Test func concurrentApprovalsAndRevocationDuringAuthentication() async throws {
        for action in ["approve", "dismiss", "revoke"] {
            let r = try Rig(), input = r.input()
            let preview = try requirePreview(r.gate.submit(try r.candidate(r.send()), input: input))
            let evidence = r.approval(preview)
            r.biometric.handler = { challenge in
                if action == "approve" {
                    #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: evidence), .invalidState))
                } else if action == "dismiss" {
                    #expect(r.gate.transition(requestID: input.requestID, to: .dismissed))
                } else { #expect(r.gate.revokeSession(r.session)) }
                return AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: r.clock.time)
            }
            let result = await r.gate.approve(requestID: input.requestID, evidence: evidence)
            if action == "approve" { _ = try requirePermit(result) }
            else { #expect(isDenied(result, .authenticationFailed)) }
            #expect(r.biometric.calls.count == 1)
        }
    }

    @Test func grantsRequireEveryScopeDimensionAndExpiry() throws {
        for changed in ["account", "actor", "device", "project", "capability", "risk", "expiry", "none", "wildcard"] {
            let r = try Rig()
            let session = r.phone.session(account: changed == "account" ? "other" : r.session.account,
                actor: changed == "actor" ? "other" : r.session.actor, session: r.session.session,
                device: changed == "device" ? "other" : r.session.device,
                project: changed == "project" ? "other" : (changed == "wildcard" ? "*" : r.session.project), destinationKind: .software)
            if changed != "none" {
                let grant = r.grant(changed == "capability" ? .cancel_task : .receive_text,
                    risk: changed == "risk" ? .workspace_modify : .read_display, session: session,
                    expiry: changed == "expiry" ? r.clock.time + 1 : nil)
                #expect(r.gate.installGrant(grant) == (changed != "wildcard"))
            }
            if changed == "expiry" { r.clock.time += 1 }
            #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.ptt)), .missingGrant))
        }
        let r = try Rig(), grant = r.grant()
        #expect(r.gate.installGrant(grant))
        #expect(r.gate.revokeGrant(grant.id, session: r.session))
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.wakeWord)), .missingGrant))
        #expect(!r.gate.installGrant(r.grant(expiry: r.clock.time)))
    }

    @Test func ambiguousMeetingWakeDowngradesEvenWithGrant() throws {
        let r = try Rig()
        #expect(r.gate.installGrant(r.grant()))
        let result = r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.wakeWord, ambiguous: true))
        guard case .suggestion = result else { Issue.record("Ambiguous wake dispatched"); return }
        #expect(!r.audit.records.contains { $0.event == .queued })
        _ = try requirePermit(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.wakeWord)))
    }

    @Test func hardwareAndDictationNeverRun() throws {
        let r = try Rig()
        let hardware = r.phone.session(account: r.session.account, actor: r.session.actor, session: r.session.session,
                                       device: r.session.device, project: r.session.project, destinationKind: .hardware)
        #expect(!r.gate.installGrant(r.grant(session: hardware)))
        for (_, tool, _, _) in try r.fixtures() {
            for kind: InputActivation in [.inferred, .ptt, .wakeWord] {
                #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(tool), input: r.input(kind, session: hardware)), .hardwarePolicyMissing))
                #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(tool), input: r.input(kind, mode: .dictation)), .dictation))
            }
        }
        let dictation = DictationText(account_id: r.session.account, segment_id: "synthetic", revision: 1,
                                      state: .committed, target_device_id: r.session.device, text: "synthetic fixture")
        #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(dictation), input: r.input(.ptt))))
    }

    @Test func crossContextAndUnsafeSchemesDeny() throws {
        let r = try Rig()
        for tool: ToolCall in [
            .selectTargetTool(SelectTargetTool(account_id: "other", device_id: r.session.device)),
            .selectTargetTool(SelectTargetTool(account_id: r.session.account, device_id: "other")),
            .delegateTaskTool(DelegateTaskTool(account_id: r.session.account, device_id: r.session.device, project_id: "other", instruction: "synthetic")),
            .cancelTaskTool(CancelTaskTool(account_id: r.session.account, command_id: "unknown"))
        ] { #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(tool), input: r.input(.ptt)), .contextMismatch)) }
        for uri in ["file:///fixture", "javascript:fixture", "hil://fixture", "https://user:password@example.invalid/"] {
            let tool = ToolCall.openResourceTool(OpenResourceTool(account_id: r.session.account, device_id: r.session.device, resource_uri: uri))
            #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(tool), input: r.input(.ptt)), .invalidProposal))
        }
    }

    @Test func proposalLifecycleExpiryAndTerminalStates() async throws {
        let r = try Rig()
        let input = r.input(expiry: r.clock.time + 1000)
        let preview = try requirePreview(r.gate.submit(try ProtocolCodec.encode(r.select()), input: input))
        #expect(!r.gate.transition(requestID: input.requestID, to: .queued))
        #expect(!r.gate.transition(requestID: input.requestID, to: .approved))
        let evidence = r.approval(preview)
        r.clock.time += 1000
        #expect(r.gate.state(requestID: input.requestID) == .expired)
        #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: evidence)))
        #expect(isDenied(r.gate.submit(try r.candidate(r.select(), expiry: r.clock.time), input: r.input())))
        let live = r.input()
        let p = try requirePreview(r.gate.submit(try ProtocolCodec.encode(r.select()), input: live))
        _ = try requirePermit(await r.gate.approve(requestID: live.requestID, evidence: r.approval(p)))
        #expect(r.gate.state(requestID: live.requestID) == .queued)
        for next: ProposalState in [.dispatched, .running, .succeeded] { #expect(r.gate.transition(requestID: live.requestID, to: next)) }
        #expect(!r.gate.transition(requestID: live.requestID, to: .running))
        for terminal: ProposalState in [.failed, .cancelled] {
            let next = r.input()
            let preview = try requirePreview(r.gate.submit(try ProtocolCodec.encode(r.select()), input: next))
            _ = try requirePermit(await r.gate.approve(requestID: next.requestID, evidence: r.approval(preview)))
            #expect(r.gate.transition(requestID: next.requestID, to: .dispatched))
            #expect(r.gate.transition(requestID: next.requestID, to: terminal))
        }
    }

    @Test func replayRunsOnceIncludingReconnectAndRestart() async throws {
        let r = try Rig(), input = r.input()
        let data = try ProtocolCodec.encode(r.select())
        let preview = try requirePreview(r.gate.submit(data, input: input))
        let permit = try requirePermit(await r.gate.approve(requestID: input.requestID, evidence: r.approval(preview)))
        for _ in 0..<3 {
            guard case .duplicate = r.gate.submit(data, input: input) else { Issue.record("Replay permitted"); return }
        }
        let freshLog = try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention())
        let restarted = try PolicyGate(audit: freshLog, biometric: r.biometric, clock: { r.clock.time })
        let newSession = r.phone.session(account: r.session.account, actor: r.session.actor, session: "reconnected",
                                         device: r.session.device, project: r.session.project, destinationKind: .software)
        let replay = r.input(.ptt, session: newSession, id: input.requestID)
        // A different payload with a consumed ID also cannot execute.
        guard case .duplicate = restarted.submit(try ProtocolCodec.encode(r.send()), input: replay) else { Issue.record("Restart replay permitted"); return }
        #expect(freshLog.records.filter { $0.event == .queued }.count == 1)
        #expect(permit.command.idempotency_key == permit.command.command_id)
    }

    @Test func revokedSessionPersistsAndGrantsAreNotRestoredImplicitly() throws {
        let r = try Rig()
        #expect(r.gate.installGrant(r.grant()))
        #expect(r.gate.revokeSession(r.session))
        let log = try AuditLog(journal: r.journal, checkpoints: r.checkpoint, retention: AuditRetention())
        let gate = try PolicyGate(audit: log, biometric: r.biometric, clock: { r.clock.time })
        #expect(isDenied(gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.ptt)), .contextMismatch))
    }

    @Test func clockErrorsAndAuditFailuresNeverReleasePermit() async throws {
        for failure in ["clock", "rollback", "append", "partial", "checkpoint", "tamper"] {
            let r = try Rig(), input = r.input()
            let preview = try requirePreview(r.gate.submit(try ProtocolCodec.encode(r.select()), input: input))
            let evidence = r.approval(preview)
            switch failure {
            case "clock": r.clock.broken = true
            case "rollback": r.clock.time -= 1
            case "append": r.journal.fail = true
            case "partial": r.journal.partial = true
            case "checkpoint": r.checkpoint.fail = true
            default: r.journal.bytes.removeLast()
            }
            #expect(isDenied(await r.gate.approve(requestID: input.requestID, evidence: evidence), .auditUnavailable))
            #expect(!r.audit.records.contains { $0.event == .queued })
            #expect(isDenied(r.gate.submit(try ProtocolCodec.encode(r.select()), input: r.input(.ptt))))
        }
    }
}
