import Foundation
#if canImport(Darwin)
import Observation
#endif
import Policy
import TrustedInput
import Router
import VoiceRemoteProtocol

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
                capabilities: wire.capabilities, available: true)
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
        connections.removeValue(forKey: device)
        for i in destinations.indices where destinations[i].id == device { destinations[i].available = false }
        try? reconnect(); onChange?()
    }
    public func choose(_ identity: SessionIdentity) throws {
        guard destinations.contains(where: { $0.session == identity }) else { throw AppRoutingError.unknownProviderSession }
        selected = identity; onChange?()
    }
    public func resolve(device: String, project: String, providerSession: String?) throws -> Destination {
        let matches = destinations.filter { $0.id == device && $0.session.workspace == project &&
            (providerSession == nil || $0.session.providerSessionID == providerSession) &&
            (selected == nil || $0.session == selected) }
        guard matches.count == 1 else { throw AppRoutingError.unknownProviderSession }
        return matches[0]
    }
    public func enqueue(_ permit: ExecutionPermit, dependencies: [String] = [], replacingCommandID: String? = nil, expectedRoute: Destination? = nil) throws -> [QueuedTask] {
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
        var rules = RoutingRules(project: project)
        rules.capability = capability
        rules.explicitTarget = destination.id; rules.explicitSession = destination.session
        rules.explicitProvider = destination.session.provider
        rules.machineDependency = destination.isCloud ? nil : destination.session.host
        rules.cloudCapable = destination.isCloud
        rules.dependencies = dependencies
        _ = try router.enqueue(permit, rules: rules, destinations: [destination], replacingCommandID: replacingCommandID)
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
    public func receive(_ status: TaskStatus, from device: String, epoch: UUID) throws {
        guard connections[device]?.epoch == epoch,
              let task = router.snapshot().first(where: { $0.command.command_id == status.command_id }),
              task.command.destination_id == device, let session = task.route?.destination.session else { return }
        try router.receive(status, from: session)
        try router.reconnect(targets: targets()); onChange?()
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
        let session = input.session(account: account, actor: actor, session: UUID().uuidString,
            device: task.command.destination_id, project: task.rules.project, destinationKind: .software)
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
        if task.state != .queued, let connection = connections[task.command.destination_id] {
            try await connection.send(.authorizedCommand(permit.command))
        }
    }
}
