import Foundation
import TrustedInput
import VoiceRemoteProtocol

public enum ProposalState: String, Sendable {
    case suggested, edited, approved, dismissed, expired, queued, dispatched, running, succeeded, failed, cancelled
}
public enum Denial: String, Sendable {
    case invalidProposal, contextMismatch, expired, invalidApproval, authenticationFailed
    case missingGrant, hardwarePolicyMissing, dictation, invalidState, replayConflict, auditUnavailable
}
public struct Preview: Sendable {
    public let requestID: UUID
    public let tool: ToolCall
    public let risk: RiskClass
    public let payloadHash: String
    /// Exact bytes covered by payloadHash. Persist/forward these bytes; another
    /// language must not reconstruct the hash by reserializing the tool.
    public let immutableBytes: Data
    public let expiresAt: Int64
    public let state: ProposalState
}
/// Only Policy constructs a permit. Execution integration must accept this type,
/// not a model-deserializable AuthorizedCommand, and deduplicate its key downstream.
public struct ExecutionPermit: Sendable {
    public let command: AuthorizedCommand
    public let immutablePreview: Data
    public let expiresAt: Int64
    fileprivate init(command: AuthorizedCommand, immutablePreview: Data, expiresAt: Int64) {
        self.command = command; self.immutablePreview = immutablePreview; self.expiresAt = expiresAt
    }
}
public enum GateDecision: Sendable {
    case suggestion(Preview), authenticationRequired(Preview), queued(ExecutionPermit)
    case duplicate, denied(Denial)
}

@MainActor public final class PolicyGate {
    public static let policyVersion = "policy-v1"
    private let audit: AuditLog
    private let biometric: any Biometric
    private let clock: () throws -> Int64
    private let approvalLifetime: Int64
    private let proposalLifetime: Int64
    private var lastTime: Int64
    private var proposals: [UUID: Proposal] = [:]
    private var issuedPermits: [String: ExecutionPermit] = [:]
    private var grants: [UUID: GrantEvidence] = [:]
    private var consumed: [String: String] = [:]
    private var commands: [String: String] = [:] // command ID → authenticated scope digest
    private var revokedGrantIDs: Set<String> = []
    private var dismissedRequests: Set<String> = []
    private var revokedSessions: Set<String> = []

    private struct Proposal {
        let input: ActivationEvidence
        let tool: ToolCall
        let capability: Capability
        let risk: RiskClass
        let bytes: Data
        let hash: String
        let key: String
        let expiresAt: Int64
        let revision: Int
        var state: ProposalState
        var authenticating = false
        var grantID: UUID? = nil
        var preview: Preview {
            Preview(requestID: input.requestID, tool: tool, risk: risk, payloadHash: hash,
                    immutableBytes: bytes, expiresAt: expiresAt, state: state)
        }
        var inferred: Bool {
            input.activation == .inferred || (input.activation == .wakeWord && input.ambiguousMeetingWake)
        }
    }
    private struct PreviewBody: Encodable {
        let policy: String; let request: UUID; let revision: Int
        let account: String; let actor: String; let session: String; let device: String; let project: String
        let tool: ToolCall; let risk: RiskClass; let expiresAt: Int64
    }

    public init(audit: AuditLog, biometric: any Biometric,
                approvalLifetimeMilliseconds: Int64 = 30_000,
                proposalLifetimeMilliseconds: Int64 = 120_000,
                clock: @escaping () throws -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard approvalLifetimeMilliseconds > 0, approvalLifetimeMilliseconds <= 300_000,
              proposalLifetimeMilliseconds > 0, proposalLifetimeMilliseconds <= 86_400_000 else { throw PolicyError.invalid }
        try audit.claim()
        self.audit = audit; self.biometric = biometric; self.clock = clock
        approvalLifetime = approvalLifetimeMilliseconds; proposalLifetime = proposalLifetimeMilliseconds
        lastTime = try audit.minimumTime()
        // Persisted reservation is the at-most-once boundary, before returning a permit.
        for record in audit.records {
            if record.event == .queued {
                consumed[record.subjectHash] = record.payloadHash
                commands[record.subjectHash] = record.scopeHash
            }
            if record.event == .grantRevoked { revokedGrantIDs.insert(record.subjectHash) }
            if record.event == .sessionRevoked { revokedSessions.insert(record.subjectHash) }
            if record.event == .dismissed { dismissedRequests.insert(record.subjectHash) }
        }
    }

    private func now() throws -> Int64 {
        let t = try clock()
        guard t >= lastTime, t >= 0, t <= 9_007_199_254_740_991 - 86_400_000 else { throw PolicyError.clock }
        lastTime = t
        return t
    }
    private func key(_ input: ActivationEvidence) -> String {
        // A reconnect uses the same phone-issued request UUID. Actor/account are
        // included, session is deliberately excluded so reconnect cannot reset it.
        identityDigest(([audit.checkpoint.authorityID].compactMap { $0 }) + [input.session.account, input.session.actor, input.requestID.uuidString])
    }
    private var activePolicyVersion: String { audit.checkpoint.authorityID.map { Self.policyVersion + ":" + $0 } ?? Self.policyVersion }
    private func sessionKey(_ session: InputSession) -> String {
        identityDigest([session.account, session.actor, session.session])
    }
    private func scopeKey(_ session: InputSession) -> String {
        identityDigest([session.account, session.actor, session.device, session.project])
    }
    private func grantKey(_ id: UUID) -> String { PayloadDigest.sha256(Data(id.uuidString.utf8)) }
    /// Defensive maxima, TBC product defaults. Sensitive grants are never valid.
    private func grantLifetime(_ risk: RiskClass) -> Int64 {
        switch risk {
        case .read_display: return 86_400_000
        case .workspace_modify: return 900_000
        case .sensitive: return 0
        }
    }
    private func valid(_ session: InputSession) -> Bool {
        [session.account, session.actor, session.session, session.device, session.project].allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.count <= 128 && $0 != "*"
        } && (audit.checkpoint.authoritySessionHash == nil || audit.checkpoint.authoritySessionHash == sessionKey(session))
          && !revokedSessions.contains(sessionKey(session))
    }
    private func record(_ event: AuditEvent, _ input: ActivationEvidence, hash: String, time: Int64) throws {
        try audit.append(event: event, subject: key(input), payloadHash: hash, actor: input.session.actor,
                         now: time, scopeHash: event == .queued ? scopeKey(input.session) : nil)
    }
    private func deny(_ reason: Denial, input: ActivationEvidence, hash: String = "", time: Int64? = nil) -> GateDecision {
        do {
            try record(.denied, input, hash: hash.isEmpty ? PayloadDigest.sha256(Data()) : hash, time: time ?? now())
            return .denied(reason)
        } catch { return .denied(.auditUnavailable) }
    }

    /// Sole model ingress. Accepts the closed ToolCall or CandidateAction schema.
    /// No typed overload lets callers bypass strict codec validation.
    public func submit(_ modelJSON: Data, input: ActivationEvidence) -> GateDecision {
        do {
            let t = try now()
            try audit.checkIntegrity()
            guard !dismissedRequests.contains(key(input)) else {
                return deny(.invalidState, input: input, time: t)
            }
            // A persisted request cannot be resubmitted, including after restart.
            if consumed[key(input)] != nil {
                try record(.duplicate, input, hash: consumed[key(input)]!, time: t)
                return .duplicate
            }
            let proposal = try build(modelJSON, input: input, revision: 0, time: t, expiryLimit: proposals[input.requestID]?.expiresAt)
            if let existing = proposals[input.requestID] {
                guard existing.hash == proposal.hash else { return deny(.replayConflict, input: input, hash: proposal.hash, time: t) }
                return evaluate(existing, time: t)
            }
            proposals[input.requestID] = proposal
            return evaluate(proposal, time: t)
        } catch let reason as BuildFailure { return deny(reason.denial, input: input) }
        catch { return deny(.invalidProposal, input: input) }
    }

    private struct BuildFailure: Error { let denial: Denial }
    private func fail(_ denial: Denial) throws -> Never { throw BuildFailure(denial: denial) }
    private func build(_ data: Data, input: ActivationEvidence, revision: Int, time: Int64, expiryLimit: Int64? = nil, riskFloor: RiskClass = .read_display) throws -> Proposal {
        guard valid(input.session) else { try fail(.contextMismatch) }
        guard input.mode == .command else { try fail(.dictation) }
        guard input.expiresAt > time else { try fail(.expired) }
        guard input.session.destinationKind == .software else { try fail(.hardwarePolicyMissing) }
        let tool: ToolCall
        var proposedRisk: RiskClass = .read_display
        var expiry = min(input.expiresAt, time + proposalLifetime, expiryLimit ?? Int64.max)
        if let candidate = try? ProtocolCodec.decode(CandidateAction.self, from: data) {
            guard candidate.account_id == input.session.account,
                  candidate.parent_capture_session == input.session.session,
                  candidate.destination_hint == nil || candidate.destination_hint == input.session.device else { try fail(.contextMismatch) }
            tool = candidate.proposed_task
            proposedRisk = candidate.proposed_risk_class
            expiry = min(expiry, candidate.suggestion_expiry)
            // candidate_state, proposed_payload_hash, confidence and capability are
            // untrusted UI hints. They never set gate state or authority.
        } else {
            tool = try ProtocolCodec.decode(ToolCall.self, from: data)
        }
        guard expiry > time else { try fail(.expired) }
        let account: String, device: String, capability: Capability, minimumRisk: RiskClass
        switch tool {
        case .selectTargetTool(let x):
            account=x.account_id; device=x.device_id; capability = .receive_text; minimumRisk = .read_display
        case .openResourceTool(let x):
            account=x.account_id; device=x.device_id; capability = .open_resource; minimumRisk = .sensitive
            // Arbitrary schemes can launch executables or hardware integrations.
            guard let url = URLComponents(string: x.resource_uri), url.scheme == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { try fail(.invalidProposal) }
        case .delegateTaskTool(let x):
            account=x.account_id; device=x.device_id; capability = .delegate_task; minimumRisk = .sensitive
            guard x.project_id == input.session.project else { try fail(.contextMismatch) }
        case .cancelTaskTool(let x):
            account=x.account_id; device=input.session.device; capability = .cancel_task; minimumRisk = .workspace_modify
            guard commands[x.command_id] == scopeKey(input.session) else { try fail(.contextMismatch) }
        case .prepareSendTool(let x):
            account=x.account_id; device=x.device_id; capability = .external_send; minimumRisk = .sensitive
        }
        guard account == input.session.account, device == input.session.device else { try fail(.contextMismatch) }
        let rank: [RiskClass: Int] = [.read_display: 0, .workspace_modify: 1, .sensitive: 2]
        let risk = [minimumRisk, proposedRisk, riskFloor].max { rank[$0]! < rank[$1]! }!
        let body = PreviewBody(policy: activePolicyVersion, request: input.requestID, revision: revision,
                               account: account, actor: input.session.actor, session: input.session.session,
                               device: device, project: input.session.project, tool: tool, risk: risk, expiresAt: expiry)
        let bytes = try canonical(body)
        return Proposal(input: input, tool: tool, capability: capability, risk: risk, bytes: bytes,
                        hash: PayloadDigest.sha256(bytes), key: key(input), expiresAt: expiry, revision: revision, state: .suggested)
    }

    private func evaluate(_ p: Proposal, time: Int64) -> GateDecision {
        guard p.state == .suggested || p.state == .edited else { return deny(.invalidState, input: p.input, hash: p.hash, time: time) }
        guard time < p.expiresAt else { return expire(p, time: time) }
        do {
            if p.inferred || p.state == .edited {
                try record(.suggested, p.input, hash: p.hash, time: time)
                return .suggestion(p.preview)
            }
            if p.risk == .sensitive {
                try record(.authenticationRequired, p.input, hash: p.hash, time: time)
                return .authenticationRequired(p.preview)
            }
            guard let grant = grants.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first(where: {
                $0.session.account == p.input.session.account && $0.session.actor == p.input.session.actor &&
                $0.session.device == p.input.session.device && $0.session.project == p.input.session.project &&
                $0.capability == p.capability && $0.risk == p.risk && $0.expiresAt > time &&
                valid($0.session) && !revokedGrantIDs.contains(grantKey($0.id))
            }) else { return deny(.missingGrant, input: p.input, hash: p.hash, time: time) }
            return try queue(p, approval: nil, credential: .scoped_grant, scope: grant.id.uuidString, time: time)
        } catch { return .denied(.auditUnavailable) }
    }

    public func approve(requestID: UUID, evidence: ApprovalEvidence) async -> GateDecision {
        guard var p = proposals[requestID] else { return denyUnknown(evidence) }
        do {
            let t = try now()
            guard valid(p.input.session), !p.authenticating,
                  p.state == .suggested || p.state == .edited else { return deny(.invalidState, input: p.input, hash: p.hash, time: t) }
            guard t < p.expiresAt else { return expire(p, time: t) }
            guard evidence.requestID == requestID, evidence.session == p.input.session,
                  evidence.payloadHash == p.hash, evidence.source == .phone,
                  evidence.occurredAt <= t, t - evidence.occurredAt < approvalLifetime else {
                return deny(.invalidApproval, input: p.input, hash: p.hash, time: t)
            }
            var credential: ApprovalCredentialClass = .user_presence
            if p.risk == .sensitive {
                try record(.authenticationRequired, p.input, hash: p.hash, time: t)
                p.authenticating = true; proposals[requestID] = p
                let challenge = AuthenticationChallenge(id: UUID(), payloadHash: p.hash, issuedAt: t,
                                                         expiresAt: min(p.expiresAt, t + approvalLifetime))
                let result: AuthenticationResult
                do { result = try await biometric.authenticate(challenge) }
                catch {
                    if proposals[requestID]?.revision == p.revision { proposals[requestID]?.authenticating = false }
                    return deny(.authenticationFailed, input: p.input, hash: p.hash)
                }
                let completed = try now()
                guard let current = proposals[requestID], current.hash == p.hash, current.authenticating,
                      current.state == p.state, valid(p.input.session), completed < challenge.expiresAt,
                      completed - evidence.occurredAt < approvalLifetime,
                      result.challenge == challenge, result.authenticatedAt >= challenge.issuedAt,
                      result.authenticatedAt <= completed,
                      result.credential == .biometric || result.credential == .passcode else {
                    if proposals[requestID]?.revision == p.revision { proposals[requestID]?.authenticating = false }
                    return deny(.authenticationFailed, input: p.input, hash: p.hash, time: completed)
                }
                credential = result.credential
            }
            let completed = try now()
            try record(.approved, p.input, hash: p.hash, time: completed)
            p.state = .approved; p.authenticating = false; proposals[requestID] = p
            return try queue(p, approval: evidence, credential: credential, scope: evidence.eventID.uuidString, time: completed)
        } catch { return .denied(.auditUnavailable) }
    }

    private func denyUnknown(_ evidence: ApprovalEvidence) -> GateDecision {
        do {
            try audit.append(event: .denied, subject: PayloadDigest.sha256(Data(evidence.requestID.uuidString.utf8)),
                             payloadHash: PayloadDigest.sha256(Data(evidence.payloadHash.utf8)),
                             actor: evidence.session.actor, now: now())
            return .denied(.invalidApproval)
        } catch { return .denied(.auditUnavailable) }
    }

    private func queue(_ p: Proposal, approval: ApprovalEvidence?, credential: ApprovalCredentialClass,
                       scope: String, time: Int64) throws -> GateDecision {
        guard consumed[p.key] == nil else {
            try record(.duplicate, p.input, hash: p.hash, time: time)
            return .duplicate
        }
        guard time < p.expiresAt, valid(p.input.session) else { return deny(.expired, input: p.input, hash: p.hash, time: time) }
        let activation: ActivationKind = approval != nil ? .approval_tap : (p.input.activation == .ptt ? .ptt : .wake_word)
        let provider: String?
        if case .delegateTaskTool(let x) = p.tool { provider = x.provider_session_id } else { provider = nil }
        let command = AuthorizedCommand(account_id: p.input.session.account, command_id: p.key,
            candidate_id: p.input.requestID.uuidString, immutable_task_payload: p.tool, payload_hash: p.hash,
            source_tier: p.inferred ? .inferred : .explicit, activation_kind: activation,
            authenticated_actor: p.input.session.actor, approval_credential_class: credential,
            approval_event_id: approval?.eventID.uuidString, risk_class: p.risk, policy_version: activePolicyVersion,
            granted_scope_id: scope, destination_id: p.input.session.device, provider_session_id: provider,
            idempotency_key: p.key, execution_state: .queued, created_at: time, updated_at: time)
        _ = try ProtocolCodec.encode(command)
        try record(.queued, p.input, hash: p.hash, time: time)
        consumed[p.key] = p.hash; commands[p.key] = scopeKey(p.input.session)
        var queued = p; queued.state = .queued; queued.authenticating = false
        queued.grantID = approval == nil ? UUID(uuidString: scope) : nil
        proposals[p.input.requestID] = queued
        let permit = ExecutionPermit(command: command, immutablePreview: p.bytes, expiresAt: p.expiresAt)
        issuedPermits[command.command_id] = permit
        return .queued(permit)
    }

    /// Revalidates retained routing storage against a permit actually issued by
    /// this live gate. Raw commands/preview hashes cannot mint authority. A new
    /// gate after restart requires reapproval, matching the existing restart rule.
    public func verifyExecution(command: AuthorizedCommand, immutablePreview: Data,
                                expiresAt: Int64) throws -> ExecutionPermit {
        try audit.checkIntegrity()
        let time = try now()
        guard let issued = issuedPermits[command.command_id], issued.command == command,
              issued.immutablePreview == immutablePreview, issued.expiresAt == expiresAt,
              PayloadDigest.sha256(immutablePreview) == command.payload_hash,
              time < expiresAt, let request = UUID(uuidString: command.candidate_id),
              let p = proposals[request], p.key == command.idempotency_key,
              p.hash == command.payload_hash, p.tool == command.immutable_task_payload,
              p.input.session.device == command.destination_id, valid(p.input.session),
              [.queued, .dispatched, .running].contains(p.state) else { throw PolicyError.invalid }
        if let id = p.grantID {
            guard let grant = grants[id], !revokedGrantIDs.contains(grantKey(id)),
                  valid(grant.session), grant.expiresAt > time else { throw PolicyError.invalid }
        }
        return issued
    }

    public func edit(requestID: UUID, modelJSON: Data) -> GateDecision {
        guard let old = proposals[requestID] else { return auditUnknownRequest(requestID) }
        do {
            let t = try now()
            guard old.state == .suggested || old.state == .edited else { return deny(.invalidState, input: old.input, hash: old.hash, time: t) }
            guard t < old.expiresAt else { return expire(old, time: t) }
            var updated = try build(modelJSON, input: old.input, revision: old.revision + 1, time: t, expiryLimit: old.expiresAt, riskFloor: old.risk)
            // Edits never extend the original context lifetime.
            guard updated.expiresAt <= old.expiresAt else { return deny(.invalidProposal, input: old.input, hash: old.hash, time: t) }
            updated.state = .edited
            try record(.edited, updated.input, hash: updated.hash, time: t)
            proposals[requestID] = updated
            return .suggestion(updated.preview)
        } catch { return deny(.invalidProposal, input: old.input, hash: old.hash) }
    }

    private func expire(_ p: Proposal, time: Int64) -> GateDecision {
        do {
            try record(.expired, p.input, hash: p.hash, time: time)
            proposals[p.input.requestID]?.state = .expired
            proposals[p.input.requestID]?.authenticating = false
            return .denied(.expired)
        } catch { return .denied(.auditUnavailable) }
    }

    /// Trusted UI dismissal or authenticated executor status, never model state.
    @discardableResult public func transition(requestID: UUID, to next: ProposalState) -> Bool {
        guard let p = proposals[requestID] else { _ = auditUnknownRequest(requestID); return false }
        do {
            let t = try now()
            guard valid(p.input.session) else {
                _ = deny(.contextMismatch, input: p.input, hash: p.hash, time: t); return false
            }
            guard t < p.expiresAt else {
                _ = deny(.expired, input: p.input, hash: p.hash, time: t); return false
            }
            if let id = p.grantID {
                guard let grant = grants[id], !revokedGrantIDs.contains(grantKey(id)),
                      valid(grant.session), grant.expiresAt > t else {
                    _ = deny(.missingGrant, input: p.input, hash: p.hash, time: t); return false
                }
            }
            let permitted: [ProposalState: Set<ProposalState>] = [
                .suggested: [.dismissed, .expired], .edited: [.dismissed, .expired],
                .queued: [.dispatched, .cancelled], .dispatched: [.running, .failed, .cancelled],
                .running: [.succeeded, .failed, .cancelled]
            ]
            guard permitted[p.state]?.contains(next) == true, let event = AuditEvent(rawValue: next.rawValue) else {
                _ = deny(.invalidState, input: p.input, hash: p.hash, time: t); return false
            }
            try record(event, p.input, hash: p.hash, time: t)
            proposals[requestID]?.state = next; proposals[requestID]?.authenticating = false
            if next == .dismissed { dismissedRequests.insert(p.key) }
            return true
        } catch { return false }
    }
    public func state(requestID: UUID) -> ProposalState? {
        guard let p = proposals[requestID] else { return nil }
        if p.state == .suggested || p.state == .edited {
            do { let t = try now(); if t >= p.expiresAt { _ = expire(p, time: t) } }
            catch { return nil }
        }
        return proposals[requestID]?.state
    }
    private func auditUnknownRequest(_ id: UUID) -> GateDecision {
        do {
            try audit.append(event: .denied, subject: PayloadDigest.sha256(Data(id.uuidString.utf8)),
                             payloadHash: PayloadDigest.sha256(Data()), actor: "", now: now())
            return .denied(.invalidState)
        } catch { return .denied(.auditUnavailable) }
    }

    @discardableResult public func installGrant(_ grant: GrantEvidence) -> Bool {
        do {
            let t = try now()
            guard valid(grant.session), grant.session.destinationKind == .software,
                  grant.expiresAt > t, grant.expiresAt <= 9_007_199_254_740_991,
                  grant.issuedAt >= 0, grant.issuedAt <= t,
                  grant.expiresAt - grant.issuedAt <= grantLifetime(grant.risk),
                  !revokedGrantIDs.contains(grantKey(grant.id)), grant.risk != .sensitive else {
                try audit.append(event: .denied, subject: PayloadDigest.sha256(Data(grant.id.uuidString.utf8)),
                                 payloadHash: PayloadDigest.sha256(Data()), actor: grant.session.actor, now: t)
                return false
            }
            let wire = Grant(account_id: grant.session.account, grant_id: grant.id.uuidString,
                             authenticated_actor: grant.session.actor, device_id: grant.session.device,
                             project_id: grant.session.project, capability: grant.capability,
                             risk_class: grant.risk, expires_at: grant.expiresAt)
            let hash = PayloadDigest.sha256(try ProtocolCodec.encode(wire))
            try audit.append(event: .grantIssued, subject: PayloadDigest.sha256(Data(grant.id.uuidString.utf8)),
                             payloadHash: hash, actor: grant.session.actor, now: t)
            grants[grant.id] = grant
            return true
        } catch { return false }
    }
    @discardableResult public func revokeGrant(_ id: UUID, session: InputSession) -> Bool {
        do {
            let allowed = valid(session) && session.destinationKind == .software &&
                grants[id].map { scopeKey($0.session) == scopeKey(session) } == true
            try audit.append(event: allowed ? .grantRevoked : .denied,
                             subject: PayloadDigest.sha256(Data(id.uuidString.utf8)),
                             payloadHash: PayloadDigest.sha256(Data()), actor: session.actor, now: now())
            if allowed { grants.removeValue(forKey: id); revokedGrantIDs.insert(grantKey(id)) }
            return allowed
        } catch { return false }
    }
    @discardableResult public func revokeSession(_ session: InputSession) -> Bool {
        do {
            try audit.append(event: .sessionRevoked, subject: sessionKey(session),
                             payloadHash: PayloadDigest.sha256(Data()), actor: session.actor, now: now())
            revokedSessions.insert(sessionKey(session))
            grants = grants.filter { sessionKey($0.value.session) != sessionKey(session) }
            return true
        } catch { return false }
    }
}
