import Foundation
#if canImport(Darwin)
import Observation
#endif
import Policy
import TrustedInput
import Router
import VoiceRemoteProtocol

public struct AgentSessionUse: Codable, Equatable, Sendable {
    public let session: SessionIdentity
    public let timestamp: Int64
}
/// Persisted phone preferences. Cloud independence is an explicit owner choice;
/// neither Brain nor a provider response can enable it.
public struct AgentRoutingSettings: Codable, Equatable, Sendable {
    public var project: String? = nil
    public var selectedSession: SessionIdentity? = nil
    public var defaultSession: SessionIdentity? = nil
    public var recent: [AgentSessionUse] = []
    public var localProviderOrder = ["codex", "claude"]
    public var cloudProviderOrder = ["cloud"]
    public var allowCloudFallback = false
    /// One phone-confirmed action only; never restored from persisted settings.
    public var independentCloudTasks = false
    private enum CodingKeys: String, CodingKey {
        case project, selectedSession, defaultSession, recent, localProviderOrder, cloudProviderOrder, allowCloudFallback
    }
    public init() {}
}

/// A live paired-session adapter. It queues transport work only after Router has
/// durably reserved dispatch. A send error retains delivery uncertainty.
public struct PairedAgentTarget: AgentAdapter {
    public let destination: Destination
    private let session: AgentSession
    private let preview: @Sendable (String) throws -> (Data, Int64)
    private let send: @Sendable (InnerMessage) throws -> Void
    public init(destination: Destination, session: AgentSession,
                preview: @escaping @Sendable (String) throws -> (Data, Int64),
                send: @escaping @Sendable (InnerMessage) throws -> Void) {
        self.destination = destination; self.session = session; self.preview = preview; self.send = send
    }
    public func dispatch(_ command: AuthorizedCommand, route: RouteChoice) throws {
        guard route.destination.session == destination.session else { throw RouterError.invalidAuthorization }
        let (bytes, expiry) = try preview(command.command_id)
        try send(.agentDispatch(AgentDispatch(account_id: command.account_id, command: command, session: session,
            immutable_preview: bytes.base64EncodedString(), expires_at: expiry)))
    }
    public func cancel(commandID: String, idempotencyKey: String) throws {
        // Cancellation needs its own fresh Policy permit, including after restore.
        throw RouterError.invalidAuthorization
    }
}

/// Per-routing-pass lookup, released with the temporary adapters. The retained
/// task store remains the only production task payload/preview persistence.
private struct AgentPreviews: Sendable {
    let values: [String: (Data, Int64)]
    init(tasks: [QueuedTask]) {
        values = Dictionary(uniqueKeysWithValues: tasks.map { ($0.command.command_id, ($0.immutablePreview, $0.permitExpiresAt)) })
    }
    func get(_ id: String) throws -> (Data, Int64) {
        guard let value = values[id] else { throw RouterError.invalidAuthorization }
        return value
    }
}

/// Trusted composition boundary. Inventory arrives only from the installed
/// paired-session reader; no Brain import or model-facing inventory setter.
#if canImport(Darwin)
@Observable
#endif
@MainActor public final class AgentControl {
    public private(set) var destinations: [Destination] = []
    public private(set) var selected: SessionIdentity?
    public private(set) var routing = AgentRoutingSettings()
    public var routingDidChange: (@MainActor (AgentRoutingSettings) -> Void)?
    public var onChange: (@MainActor () -> Void)?
    private struct Connection {
        let epoch: UUID
        let device: DeviceInfo
        let request: String
        let send: @Sendable (InnerMessage) async throws -> Void
    }
    private var connections: [String: Connection] = [:]
    private var inventory: [SessionIdentity: AgentSession] = [:]
    private var cancellationPermits: [String: ExecutionPermit] = [:]
    private struct Query {
        let token: UUID
        let device: String
        let epoch: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var queries: [String: Query] = [:]
    /// Sleep ends the opportunity to execute queued work. A fresh connection can
    /// query existing identities, but only a new phone approval can release a hold.
    public func prepareForWake() throws {
        let pending = queries; queries.removeAll()
        for query in pending.values { query.continuation.resume(throwing: RouterError.invalidStatus) }
        connections.removeAll(); inventory.removeAll(); cancellationPermits.removeAll()
        for i in destinations.indices { destinations[i].available = false }
        for task in router.snapshot() where task.state == .queued {
            if let id = UUID(uuidString: task.command.candidate_id) {
                _ = policy.transition(requestID: id, to: .cancelled)
            }
        }
        try router.reconnect(targets: [])
        onChange?()
    }
    public let router: TaskRouter
    private let policy: PolicyGate
    private let input: PhoneInput
    private let account: String
    private let actor: String
    private let now: () -> Int64
    public init(router: TaskRouter, policy: PolicyGate, account: String, actor: String,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.router = router; self.policy = policy; self.account = account; self.actor = actor; self.now = now
        input = PhoneInput(now: now)
    }
    public func connected(_ device: DeviceInfo, epoch: UUID,
                          send: @escaping @Sendable (InnerMessage) async throws -> Void) async throws {
        guard device.account_id == account, device.capabilities.contains(.delegate_task),
              device.role == .agent || device.role == .both else { return }
        if connections[device.device_id]?.epoch == epoch { return }
        let request = UUID().uuidString
        connections[device.device_id] = Connection(epoch: epoch, device: device, request: request, send: send)
        try await send(.agentInventoryRequest(AgentInventoryRequest(account_id: account, request_id: request)))
    }
    public func receive(_ value: AgentInventory, from device: String, epoch: UUID) throws {
        _ = try ProtocolCodec.encode(value)
        guard let connection = connections[device], connection.epoch == epoch,
              value.request_id == connection.request, value.account_id == account,
              value.device_id == device, value.authenticated_actor == actor else { throw RouterError.invalidStatus }
        var seen = Set<SessionIdentity>()
        let additions = try value.sessions.map { wire -> Destination in
            guard wire.account_id == account, wire.device_id == device,
                  Set(wire.capabilities).isSubset(of: Set(connection.device.capabilities)) else { throw RouterError.invalidStatus }
            let identity = SessionIdentity(provider: wire.provider.rawValue, account: account, host: device,
                workspace: wire.project_id, providerSessionID: wire.provider_session_id,
                capabilityProfile: wire.capability_profile.rawValue, executionWorkspace: wire.workspace)
            guard seen.insert(identity).inserted else { throw RouterError.invalidStatus }
            return Destination(id: device, session: identity, isCloud: wire.provider == .cloud,
                capabilities: wire.capabilities, available: true, lastUsed: routing.recent.first(where: { $0.session == identity })?.timestamp ?? 0)
        }
        // Commit only a fully validated snapshot. Removed sessions remain offline
        // for existing tasks; new inventory never silently changes a pinned route.
        for i in destinations.indices where destinations[i].id == device { destinations[i].available = false }
        for (destination, wire) in zip(additions, value.sessions) {
            destinations.removeAll { $0.session == destination.session }
            destinations.append(destination); inventory[destination.session] = wire
        }
        try reconnect(); onChange?()
    }
    public func disconnected(_ device: String, epoch: UUID) {
        guard connections[device]?.epoch == epoch else { return }
        for (id, query) in queries where query.device == device && query.epoch == epoch {
            finishQuery(id, token: query.token, error: RouterError.invalidStatus)
        }
        connections.removeValue(forKey: device)
        for i in destinations.indices where destinations[i].id == device { destinations[i].available = false }
        try? reconnect(); onChange?()
    }
    public func choose(_ identity: SessionIdentity) throws {
        guard destinations.contains(where: { $0.session == identity }) else { throw AppRoutingError.unknownProviderSession }
        selected = identity; routing.selectedSession = identity; routing.project = identity.workspace
        routingDidChange?(routing); onChange?()
    }
    public func resolve(device: String, project: String, providerSession: String?) throws -> Destination {
        let matches = destinations.filter { $0.id == device && $0.session.workspace == project &&
            (providerSession == nil || $0.session.providerSessionID == providerSession) }
        guard matches.count == 1 else { throw AppRoutingError.unknownProviderSession }
        return matches[0]
    }
    public func configureRouting(_ value: AgentRoutingSettings) {
        // Reject persisted identities from another installation/account.
        guard [value.selectedSession, value.defaultSession].compactMap({ $0 }).allSatisfy({ $0.account == account }),
              value.recent.allSatisfy({ $0.session.account == account && $0.timestamp >= 0 }), value.recent.count <= 256 else { return }
        routing = value; selected = value.selectedSession
        for i in destinations.indices {
            let d = destinations[i]
            destinations[i] = Destination(id: d.id, session: d.session, isCloud: d.isCloud, capabilities: d.capabilities,
                available: d.available, lastUsed: value.recent.first(where: { $0.session == d.session })?.timestamp ?? 0)
        }
        onChange?()
    }
    public func makeDefault(_ identity: SessionIdentity) throws {
        guard destinations.contains(where: { $0.session == identity }) else { throw AppRoutingError.unknownProviderSession }
        routing.defaultSession = identity; routing.project = identity.workspace
        routingDidChange?(routing); onChange?()
    }
    public func clearSelection() {
        selected = nil; routing.selectedSession = nil; routingDidChange?(routing); onChange?()
    }
    /// Five-step resolver input, populated from authenticated inventory and phone settings.
    /// Textual names constrain routing; they never create authority or new sessions.
    public func routingRules(project: String, text: String = "", capability: Capability = .delegate_task) throws -> RoutingRules {
        var rules = RoutingRules(project: project)
        rules.capability = capability
        rules.selectedSession = selected; rules.selectedTarget = selected?.host
        rules.defaultSession = routing.defaultSession; rules.defaultTarget = routing.defaultSession?.host
        rules.localProviderOrder = routing.localProviderOrder; rules.cloudProviderOrder = routing.cloudProviderOrder
        rules.allowCloudFallback = routing.allowCloudFallback
        rules.cloudCapable = routing.independentCloudTasks && capability == .delegate_task
        // Bind machine ownership after priority resolution. A lower-priority
        // default must not veto a recent available session on another host.
        rules.machineDependency = nil
        let normalized = text.lowercased()
        func mentions(_ name: String) -> Bool {
            normalized.range(of: "(?<![\\p{L}\\p{N}_-])" + NSRegularExpression.escapedPattern(for: name.lowercased()) + "(?![\\p{L}\\p{N}_-])", options: .regularExpression) != nil
        }
        let hosts = Set(destinations.filter { mentions($0.id) }.map(\.id))
        let providers = Set(destinations.filter { mentions($0.session.provider) }.map { $0.session.provider })
        // Session is an ordinary noun in task content. Only an explicit routing
        // phrase names a session; a bare “session timeout” creates no constraint.
        let sessionPattern = #"\bin session\s+([a-z0-9_-]+)"#
        let sessionName: String? = normalized.range(of: sessionPattern, options: .regularExpression).flatMap {
            normalized[$0].split(whereSeparator: \.isWhitespace).last.map(String.init)
        }
        let sessions = Set(destinations.filter { $0.session.providerSessionID.lowercased() == sessionName }.map(\.session))
        guard hosts.count <= 1, providers.count <= 1, sessions.count <= 1 else { throw AppRoutingError.unknownProviderSession }
        rules.explicitTarget = hosts.first; rules.explicitHost = hosts.first
        rules.explicitProvider = providers.first; rules.explicitSession = sessions.first
        // An unknown named session/provider/host must not fall through to a default.
        for marker in ["on host", "using provider", "in session"] {
            if let range = normalized.range(of: "\\b" + marker + "\\s+([a-z0-9_-]+)", options: .regularExpression) {
                let value = normalized[range].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                let known = destinations.contains { $0.id.lowercased() == value || $0.session.provider.lowercased() == value || $0.session.providerSessionID.lowercased() == value }
                guard known else { throw AppRoutingError.unknownProviderSession }
            }
        }
        if !rules.cloudCapable, let explicitHost = rules.explicitHost ?? rules.explicitSession?.host { rules.machineDependency = explicitHost }
        return rules
    }
    public func updatedRules(_ previous: RoutingRules) -> RoutingRules {
        var rules = previous
        rules.selectedSession = selected; rules.selectedTarget = selected?.host
        rules.defaultSession = routing.defaultSession; rules.defaultTarget = routing.defaultSession?.host
        rules.allowCloudFallback = routing.allowCloudFallback
        rules.localProviderOrder = routing.localProviderOrder; rules.cloudProviderOrder = routing.cloudProviderOrder
        // Independence is fixed per approved action; changing a setting cannot
        // convert existing machine/file-dependent work into a cloud task.
        return rules
    }
    public func plan(_ rules: RoutingRules) -> RouteDecision {
        RouteResolver.resolve(rules: rules, destinations: destinations)
    }
    /// An unavailable, exactly known local destination can still be reviewed
    /// for a durable hold. This never changes live availability or implies delivery.
    public func reviewDestination(_ rules: RoutingRules) -> Destination? {
        switch plan(rules) {
        case .dispatch(let choice): return choice.destination
        case .hold(let reason):
            guard reason == .unavailable || reason == .machineRequired else { return nil }
            let candidates = destinations.filter { d in
                !d.isCloud && !d.available && d.session.workspace == rules.project && d.capabilities.contains(rules.capability) &&
                (rules.explicitTarget == nil || d.id == rules.explicitTarget) &&
                (rules.explicitHost == nil || d.session.host == rules.explicitHost) &&
                (rules.explicitProvider == nil || d.session.provider == rules.explicitProvider) &&
                (rules.explicitSession == nil || d.session == rules.explicitSession) &&
                (rules.machineDependency == nil || d.session.host == rules.machineDependency)
            }
            for identity in [rules.explicitSession, rules.selectedSession, rules.defaultSession].compactMap({ $0 }) {
                if let destination = candidates.first(where: { $0.session == identity }) { return destination }
            }
            return candidates.count == 1 ? candidates.first : nil
        }
    }
    public func enqueue(_ permit: ExecutionPermit, dependencies: [String] = [], replacingCommandID: String? = nil, expectedRoute: Destination? = nil, routingRules plannedRules: RoutingRules? = nil) throws -> [QueuedTask] {
        if case .cancelTaskTool(let tool) = permit.command.immutable_task_payload {
            guard let original = router.snapshot().first(where: { $0.command.command_id == tool.command_id }) else { throw RouterError.invalidAuthorization }
            try router.recordCancellation(permit)
            cancellationPermits[tool.command_id] = permit
            if original.state != .queued, let connection = connections[original.command.destination_id] {
                Task { try? await connection.send(.authorizedCommand(permit.command)) }
            }
            onChange?(); return router.snapshot()
        }
        let project: String, capability: Capability
        switch permit.command.immutable_task_payload {
        case .delegateTaskTool(let tool): project = tool.project_id; capability = .delegate_task
        case .openResourceTool:
            let preview = try JSONSerialization.jsonObject(with: permit.immutablePreview) as? [String: Any]
            guard let value = preview?["project"] as? String else { throw RouterError.invalidAuthorization }
            project = value; capability = .open_resource
        default: throw AppRoutingError.unsupportedAction
        }
        let destination = try resolve(device: permit.command.destination_id, project: project, providerSession: permit.command.provider_session_id)
        guard expectedRoute == nil || (expectedRoute?.session == destination.session && expectedRoute?.capabilities == destination.capabilities && expectedRoute?.isCloud == destination.isCloud) else { throw RouterError.invalidAuthorization }
        guard destination.capabilities.contains(capability) else { throw AppRoutingError.unavailableDestination }
        if let plannedRules, let expectedRoute {
            guard let live = reviewDestination(updatedRules(plannedRules)), live.session == expectedRoute.session,
                  live.capabilities == expectedRoute.capabilities else { throw RouterError.invalidAuthorization }
        }
        var rules = plannedRules ?? RoutingRules(project: project)
        rules.capability = capability
        if plannedRules == nil {
        rules.explicitTarget = destination.id; rules.explicitSession = destination.session
        rules.explicitProvider = destination.session.provider
        rules.machineDependency = destination.isCloud ? nil : destination.session.host
        rules.cloudCapable = destination.isCloud
        }
        if !rules.cloudCapable, rules.machineDependency == nil { rules.machineDependency = destination.session.host }
        rules.dependencies = dependencies
        _ = try router.enqueue(permit, rules: rules, approvedDestination: destination, destinations: plannedRules == nil ? [destination] : destinations.filter { $0.session.workspace == project && $0.capabilities.contains(capability) }, replacingCommandID: replacingCommandID)
        routing.independentCloudTasks = false
        routing.recent.removeAll { $0.session == destination.session }
        routing.recent.insert(AgentSessionUse(session: destination.session, timestamp: now()), at: 0)
        routing.recent = Array(routing.recent.prefix(256)); configureRouting(routing); routingDidChange?(routing)
        try reconnect(); onChange?(); return router.snapshot()
    }
    private func targets() -> [any Target] {
        let previews = AgentPreviews(tasks: router.snapshot())
        return destinations.compactMap { destination in
            guard destination.available, let wire = inventory[destination.session],
                  let connection = connections[destination.id] else { return nil }
            return PairedAgentTarget(destination: destination, session: wire, preview: { try previews.get($0) }, send: { message in
                Task { @MainActor [weak self] in
                    guard let self, self.connections[destination.id]?.epoch == connection.epoch else { return }
                    // Router already persisted dispatched. Failure cannot authorize retry.
                    try? await connection.send(message)
                }
            })
        }
    }
    public func reconnect() throws {
        try router.reconnect(targets: targets())
        for task in router.snapshot() where task.state != .queued {
            if task.cancellationRequested, let permit = cancellationPermits[task.command.command_id],
               (try? policy.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)) != nil,
               let connection = connections[task.command.destination_id] {
                Task { try? await connection.send(.authorizedCommand(permit.command)) }
            }
            if let connection = connections[task.command.destination_id] {
                let query = AgentTaskQuery(account_id: account, command_id: task.command.command_id)
                Task { try? await connection.send(.agentTaskQuery(query)) }
            }
        }
    }
    public func completionEpoch(for task: QueuedTask) -> UUID? {
        guard task.command.account_id == account, task.command.authenticated_actor == actor,
              task.state == .dispatched, task.outcome == .dispatched, !task.cancellationRequested,
              let route = task.route?.destination,
              destinations.contains(where: { $0.session == route.session && $0.available }),
              router.snapshot().contains(where: { $0 == task }) else { return nil }
        return connections[task.command.destination_id]?.epoch
    }
    public func confirmOwnerCompletion(_ task: QueuedTask, epoch: UUID, evidence: OwnerCompletionEvidence) throws {
        guard completionEpoch(for: task) == epoch, evidence.session.session == epoch.uuidString,
              evidence.operationHash == (try TaskRouter.completionOperation(task)) else { throw RouterError.invalidStatus }
        let receipt = try policy.confirmOwnerCompletion(evidence, command: task.command, immutablePreview: task.immutablePreview)
        try router.confirmOwnerCompletion(receipt)
        try reconnect(); onChange?()
    }
    public func receive(_ status: TaskStatus, from device: String, epoch: UUID) throws {
        guard connections[device]?.epoch == epoch,
              let task = router.snapshot().first(where: { $0.command.command_id == status.command_id }),
              task.command.destination_id == device, let session = task.route?.destination.session else { return }
        // CLI/agent turns attest delivery only. This surface has no independently
        // verified effect-success contract; only the phone owner can complete it.
        guard status.execution_state != .succeeded else { throw RouterError.invalidStatus }
        try router.receive(status, from: session)
        if let query = queries[status.command_id], query.device == device, query.epoch == epoch {
            finishQuery(status.command_id, token: query.token, error: nil)
        }
        try router.reconnect(targets: targets()); onChange?()
    }
    /// Background completion waits for authenticated executor observations,
    /// rather than treating a socket write as reconciliation. Queries carry IDs
    /// only; timeout/cancellation preserves durable unconfirmed task state.
    public func reconcileTasks(on device: String, epoch: UUID, timeout: Duration = .seconds(3)) async throws {
        let account = account
        let pending = router.snapshot().filter { $0.command.destination_id == device && ($0.state == .dispatched || $0.state == .running) }
        for task in pending {
            guard let connection = connections[device], connection.epoch == epoch else { throw RouterError.invalidStatus }
            let id = task.command.command_id, token = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard queries[id] == nil else { continuation.resume(throwing: RouterError.invalidStatus); return }
                    queries[id] = Query(token: token, device: device, epoch: epoch, continuation: continuation)
                    Task { [weak self] in
                        do { try await connection.send(.agentTaskQuery(AgentTaskQuery(account_id: account, command_id: id))) }
                        catch { self?.finishQuery(id, token: token, error: error) }
                    }
                    Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.finishQuery(id, token: token, error: RouterError.invalidStatus)
                    }
                }
            } onCancel: { Task { @MainActor [weak self] in self?.finishQuery(id, token: token, error: CancellationError()) } }
        }
    }
    private func finishQuery(_ id: String, token: UUID, error: (any Error)?) {
        guard let query = queries[id], query.token == token else { return }
        queries.removeValue(forKey: id)
        if let error { query.continuation.resume(throwing: error) } else { query.continuation.resume() }
    }
    public func revoked(_ device: String) {
        if let connection = connections[device] { disconnected(device, epoch: connection.epoch) }
        for task in router.snapshot() where task.command.destination_id == device {
            if let id = UUID(uuidString: task.command.candidate_id) { _ = policy.transition(requestID: id, to: .cancelled) }
        }
        selected = selected?.host == device ? nil : selected
        try? reconnect(); onChange?()
    }
    public func cancel(_ task: QueuedTask) async throws {
        guard task.command.account_id == account, task.command.authenticated_actor == actor else { throw RouterError.invalidAuthorization }
        guard let live = router.snapshot().first(where: { $0.command == task.command }) else { throw RouterError.invalidAuthorization }
        let session = input.session(account: account, actor: actor, session: UUID().uuidString,
            device: live.command.destination_id, project: live.rules.project, destinationKind: .software)
        let id = task.command.command_id
        let permit: ExecutionPermit
        if let retained = cancellationPermits[id],
           (try? policy.verifyExecution(command: retained.command, immutablePreview: retained.immutablePreview, expiresAt: retained.expiresAt)) != nil { permit = retained }
        else {
            let tool = ToolCall.cancelTaskTool(CancelTaskTool(account_id: account, command_id: id))
            let evidence = input.activation(session: session, kind: .inferred, expiresAt: now() + 30_000)
            guard case .suggestion(let preview) = policy.submit(try ProtocolCodec.encode(tool), input: evidence),
                  case .queued(let approved) = await policy.approve(requestID: preview.requestID,
                    evidence: input.approval(session: session, requestID: preview.requestID, payloadHash: preview.payloadHash)) else { throw RouterError.invalidAuthorization }
            permit = approved; cancellationPermits[id] = approved
        }
        try router.recordCancellation(permit)
        onChange?()
        // Approval can suspend. Read again after recording the cancellation so
        // a held card which dispatched during approval still sends its control.
        if let current = router.snapshot().first(where: { $0.command == task.command }),
           current.cancellationRequested, current.state == .dispatched || current.state == .running,
           let connection = connections[current.command.destination_id] {
            try await connection.send(.authorizedCommand(permit.command))
        }
    }
}

/// Keep the editable text separate from its normalized provider order. A trailing
/// comma remains visible while the next provider is being typed.
public struct ProviderOrderDraft: Equatable, Sendable {
    public var text: String
    public init(text: String = "") { self.text = text }
    public var providers: [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}
