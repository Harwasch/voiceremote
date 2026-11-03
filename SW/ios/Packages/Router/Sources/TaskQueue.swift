import Foundation
import VoiceRemoteProtocol
import Policy
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@_silgen_name("flock") private func queueFlock(_ fd: Int32, _ operation: Int32) -> Int32

public enum RouterError: Error { case invalidAuthorization, conflictingKey, invalidStatus, storeLocked, persistence }

/// An authenticated transport plugin. Returning from dispatch means submitted,
/// never succeeded. Reconcile using authenticated status, never blind resend.
public protocol Target: Sendable {
    var destination: Destination { get }
    func dispatch(_ command: AuthorizedCommand, route: RouteChoice) throws
    /// Idempotent cancellation; repeated requests share a cancellation-only key.
    func cancel(commandID: String, idempotencyKey: String) throws
}

public protocol AgentAdapter: Target {}

public struct QueuedTask: Codable, Equatable, Sendable {
    public let command: AuthorizedCommand
    public let immutablePreview: Data
    public let permitExpiresAt: Int64
    public let rules: RoutingRules
    public let permittedDestinations: [Destination]
    public var state: ExecutionState = .queued
    public var hold: HoldReason?
    public var route: RouteChoice?
    public var cancellationRequested = false
    public var outcome: TaskStatusOutcome?
    public var updatedAt: Int64

    public var visibleStatus: String {
        if let hold { return "Held · \(hold.rawValue) · \(route?.label ?? rules.explicitTarget ?? rules.selectedTarget ?? rules.defaultTarget ?? "destination unavailable")" }
        return "\(state.rawValue) · \(route?.label ?? "awaiting destination")"
    }
}

/// One queue owner per store. A save must atomically replace and durably flush
/// the snapshot before returning. Compare-and-swap against previous under a
/// lock prevents two router instances from claiming the same dispatch.
/// An error must never be interpreted as a save.
public protocol TaskQueueStore: Sendable {
    func load() throws -> [QueuedTask]
    func save(_ tasks: [QueuedTask], replacing previous: [QueuedTask]) throws
    /// App retention can hide retired payloads from in-memory routing snapshots
    /// without changing the compare-and-swap snapshot used by persistence.
    func retainedTasks(_ tasks: [QueuedTask]) -> [QueuedTask]
}
public extension TaskQueueStore {
    func retainedTasks(_ tasks: [QueuedTask]) -> [QueuedTask] { tasks }
}

/// Exclusive process-lifetime lease, private files, atomic rename and fsync.
/// Supply an app-private directory. Encryption/relay replication belong to the app.
public final class FileTaskQueueStore: TaskQueueStore, @unchecked Sendable {
    private let url: URL
    private let lease: Int32
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        lease = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard lease >= 0 else { throw RouterError.persistence }
        guard queueFlock(lease, LOCK_EX | LOCK_NB) == 0 else { close(lease); throw RouterError.storeLocked }
    }
    deinit { close(lease) }

    public func load() throws -> [QueuedTask] {
        lock.lock(); defer { lock.unlock() }
        return try readSnapshot()
    }

    private func readSnapshot() throws -> [QueuedTask] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([QueuedTask].self, from: Data(contentsOf: url))
    }

    public func save(_ tasks: [QueuedTask], replacing previous: [QueuedTask]) throws {
        lock.lock(); defer { lock.unlock() }
        guard try readSnapshot() == previous else { throw RouterError.persistence }
        let data = try JSONEncoder().encode(tasks)
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw RouterError.persistence }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temp.path, url.path) == 0 else { throw RouterError.persistence }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw RouterError.persistence }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw RouterError.persistence }
    }
}

/// Capture-independent durable queue. Synchronous plugin calls serialize the
/// persist-before-send boundary; plugins enqueue transport work and return promptly.
@MainActor public final class TaskRouter {
    private let policy: PolicyGate
    private let store: any TaskQueueStore
    private var tasks: [QueuedTask]
    private var storageUncertain = false
    private var confirmedSuccesses = Set<String>()

    public init(store: any TaskQueueStore, policy: PolicyGate) throws {
        self.policy = policy
        self.store = store
        tasks = try store.load()
        var keys = Set<String>()
        var commands = Set<[String]>()
        let loaded = tasks
        for index in tasks.indices {
            let task = tasks[index]
            do { try verify(task) }
            catch {
                if task.state == .queued { tasks[index].hold = .reapprovalRequired }
                else if task.state == .running || task.state == .dispatched { tasks[index].hold = .deliveryUnknown }
            }
            guard keys.insert(Self.key(task.command)).inserted,
                  commands.insert([task.command.account_id, task.command.command_id]).inserted else {
                throw RouterError.conflictingKey
            }
        }
        if tasks != loaded { try store.save(tasks, replacing: loaded) }
    }

    private func verify(_ task: QueuedTask) throws {
        _ = try policy.verifyExecution(command: task.command, immutablePreview: task.immutablePreview, expiresAt: task.permitExpiresAt)
        try Self.validate(task.command, task.rules, task.permittedDestinations)
        if let route = task.route {
            guard route.destination.id == task.command.destination_id,
                  task.command.provider_session_id == nil || task.command.provider_session_id == route.destination.session.providerSessionID else {
                throw RouterError.invalidAuthorization
            }
        }
    }

    private static func key(_ c: AuthorizedCommand) -> String {
        // JSON encoding avoids delimiter collisions in opaque IDs.
        String(data: try! JSONEncoder().encode([c.account_id, c.idempotency_key]), encoding: .utf8)!
    }

    private static func validate(_ c: AuthorizedCommand, _ r: RoutingRules, _ allowed: [Destination]) throws {
        _ = try ProtocolCodec.encode(c)
        guard c.execution_state == .queued, c.outcome == nil,
              !allowed.isEmpty, Set(allowed.map(\.id)).count == allowed.count,
              allowed.allSatisfy({ $0.session.account == c.account_id && $0.session.workspace == r.project }),
              allowed.contains(where: { $0.id == c.destination_id }),
              c.provider_session_id == nil || allowed.contains(where: {
                  $0.id == c.destination_id && $0.session.providerSessionID == c.provider_session_id
              }) else { throw RouterError.invalidAuthorization }
        // Target-dependent tools cannot be reinterpreted at a different machine.
        switch c.immutable_task_payload {
        case .delegateTaskTool(let tool):
            guard tool.account_id == c.account_id, tool.device_id == c.destination_id,
                  tool.project_id == r.project, r.capability == .delegate_task,
                  tool.provider_session_id == nil || tool.provider_session_id == c.provider_session_id else {
                throw RouterError.invalidAuthorization
            }
        case .openResourceTool(let tool):
            guard tool.account_id == c.account_id, tool.device_id == c.destination_id,
                  r.capability == .open_resource,
                  let host = r.machineDependency,
                  allowed.allSatisfy({ $0.session.host == host }) else { throw RouterError.invalidAuthorization }
        default: throw RouterError.invalidAuthorization // separate executors for send/select/cancel tools
        }
    }

    @discardableResult
    public func enqueue(_ permit: ExecutionPermit, rules: RoutingRules, destinations allowed: [Destination], replacingCommandID: String? = nil) throws -> QueuedTask {
        let c = permit.command
        _ = try policy.verifyExecution(command: c, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
        try Self.validate(c, rules, allowed)
        if let task = tasks.first(where: { Self.key($0.command) == Self.key(c) ||
            ($0.command.account_id == c.account_id && $0.command.command_id == c.command_id) }) {
            guard task.command == c, task.rules == rules, task.permittedDestinations == allowed else {
                throw RouterError.conflictingKey
            }
            return task
        }
        let task = QueuedTask(command: c, immutablePreview: permit.immutablePreview, permitExpiresAt: permit.expiresAt, rules: rules, permittedDestinations: allowed, updatedAt: c.updated_at)
        var next = tasks
        if let replacing = replacingCommandID {
            guard let index = next.firstIndex(where: { $0.command.command_id == replacing }),
                  next[index].state == .queued, next[index].hold == .reapprovalRequired,
                  next[index].command.account_id == c.account_id,
                  next[index].command.authenticated_actor == c.authenticated_actor,
                  next[index].command.destination_id == c.destination_id,
                  next[index].command.immutable_task_payload == c.immutable_task_payload else { throw RouterError.invalidAuthorization }
            next[index].state = .cancelled; next[index].hold = nil; next[index].cancellationRequested = true
        }
        next.append(task)
        try persist(next)
        return task
    }

    public func snapshot() -> [QueuedTask] { store.retainedTasks(tasks) }

    private func persist(_ next: [QueuedTask]) throws {
        guard !storageUncertain else { throw RouterError.persistence }
        do { try store.save(next, replacing: tasks); tasks = next }
        catch { storageUncertain = true; throw error } // reopen/reconcile after uncertain storage failure
    }

    /// Retry only queued tasks, and only through exactly the destinations approved
    /// by policy. Alternate route candidates require a new approved command;
    /// registry changes never expand permissions or session identity.
    public func reconnect(targets: [any Target]) throws {
        guard !storageUncertain else { throw RouterError.persistence }
        for task in tasks where task.cancellationRequested && !Self.terminal(task.state) {
            // A transport failure belongs to this task; other tasks still progress.
            do { try deliverCancellation(task, targets: targets) }
            catch { if storageUncertain { throw error } }
        }
        for index in tasks.indices where tasks[index].state == .queued && !tasks[index].cancellationRequested {
            let task = tasks[index]
            do { try verify(task) }
            catch {
                var held = tasks; held[index].hold = .reapprovalRequired
                try persist(held); continue
            }
            if let dependencies = task.rules.dependencies, !dependencies.allSatisfy({ id in
                tasks.contains { $0.command.command_id == id && $0.command.account_id == task.command.account_id &&
                    $0.command.authenticated_actor == task.command.authenticated_actor && $0.state == .succeeded &&
                    $0.outcome == .ok && !$0.cancellationRequested && confirmedSuccesses.contains(id) }
            }) {
                var held = tasks; held[index].hold = .predecessorRequired
                try persist(held); continue
            }
            let requested = task.rules.explicitTarget ?? task.rules.selectedTarget ??
                (task.rules.mode == .dictation ? task.rules.activeTextField : nil)
            if let requested, requested != task.command.destination_id {
                var held = tasks; held[index].hold = .reapprovalRequired
                try persist(held); continue
            }
            let available = task.permittedDestinations.map { permitted in
                var d = permitted
                d.available = targets.contains { plugin in
                    let live = plugin.destination
                    return live.id == permitted.id && live.session == permitted.session &&
                        live.isCloud == permitted.isCloud && live.capabilities == permitted.capabilities && live.available
                }
                return d
            }
            var next = tasks
            switch RouteResolver.resolve(rules: task.rules, destinations: available) {
            case .hold(let reason):
                next[index].hold = reason
                try persist(next)
            case .dispatch(let choice):
                // Routing chooses a candidate; it cannot change what was approved.
                guard choice.destination.id == task.command.destination_id,
                      task.command.provider_session_id == nil || task.command.provider_session_id == choice.destination.session.providerSessionID else {
                    next[index].hold = .reapprovalRequired
                    try persist(next); continue
                }
                guard let target = targets.first(where: { $0.destination.id == choice.destination.id &&
                    $0.destination.session == choice.destination.session &&
                    $0.destination.isCloud == choice.destination.isCloud &&
                    $0.destination.capabilities == choice.destination.capabilities && $0.destination.available }) else { continue }
                next[index].route = choice
                next[index].state = .dispatched
                next[index].hold = .deliveryUnknown
                // Crash here can lose delivery, but cannot cause a second attempt.
                try persist(next)
                do {
                    try target.dispatch(task.command, route: choice)
                    next[index].hold = nil
                    try persist(next)
                } catch {
                    // The adapter may have sent before throwing. Preserve uncertain
                    // delivery and do not report failure/success or resend.
                    if storageUncertain { throw error }
                }
            }
        }
    }

    /// A fresh, sealed cancellation permit remains usable when the original task
    /// expired or was restored under a new gate. Never restore execution authority.
    public func recordCancellation(_ permit: ExecutionPermit) throws {
        _ = try policy.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
        let c = permit.command
        guard case .cancelTaskTool(let tool) = c.immutable_task_payload,
              let index = tasks.firstIndex(where: { $0.command.command_id == tool.command_id &&
                $0.command.account_id == c.account_id && $0.command.authenticated_actor == c.authenticated_actor &&
                $0.command.destination_id == c.destination_id }) else { throw RouterError.invalidAuthorization }
        guard !Self.terminal(tasks[index].state) else { return }
        var next = tasks; next[index].cancellationRequested = true
        if next[index].state == .queued { next[index].state = .cancelled; next[index].hold = nil }
        else { next[index].hold = .cancellationPending }
        try persist(next)
    }

    /// The app authenticates the caller. Cancellation is not proof physical work stopped.
    public func cancel(accountID: String, commandID: String, targets: [any Target]) throws {
        guard let index = tasks.firstIndex(where: { $0.command.account_id == accountID && $0.command.command_id == commandID }) else { return }
        guard !Self.terminal(tasks[index].state), !tasks[index].cancellationRequested else { return }
        var next = tasks
        next[index].cancellationRequested = true
        if next[index].state == .queued {
            next[index].state = .cancelled; next[index].hold = nil
        } else { next[index].hold = .cancellationPending }
        try persist(next)
        try deliverCancellation(next[index], targets: targets)
    }

    private func deliverCancellation(_ task: QueuedTask, targets: [any Target]) throws {
        guard !storageUncertain else { throw RouterError.persistence }
        try verify(task)
        if let route = task.route, let target = targets.first(where: {
            $0.destination.id == route.destination.id && $0.destination.session == route.destination.session &&
            $0.destination.isCloud == route.destination.isCloud &&
            $0.destination.capabilities == route.destination.capabilities && $0.destination.available
        }) {
            // Distinct operation key; plugins must deduplicate repeated cancellation.
            try target.cancel(commandID: task.command.command_id, idempotencyKey: "cancel:" + task.command.idempotency_key)
        }
    }

    /// Only an authenticated adapter status for the dispatched identity can finish
    /// a task. UI/model state and dispatch acknowledgements cannot set success.
    public func receive(_ status: TaskStatus, from session: SessionIdentity) throws {
        _ = try ProtocolCodec.encode(status)
        guard let i = tasks.firstIndex(where: { $0.command.account_id == status.account_id && $0.command.command_id == status.command_id }),
              tasks[i].route?.destination.session == session else { throw RouterError.invalidStatus }
        let old = tasks[i].state
        let new = status.execution_state
        if old == new && Self.terminal(old) {
            if new == .succeeded, status.outcome == .ok { confirmedSuccesses.insert(status.command_id) }
            return
        }
        guard !Self.terminal(old), old != .queued, new != .queued,
              !(old == .running && new == .dispatched),
              new != .succeeded || status.outcome == .ok else { throw RouterError.invalidStatus }
        var next = tasks
        next[i].state = new
        next[i].outcome = status.outcome
        next[i].updatedAt = status.updated_at
        next[i].hold = next[i].cancellationRequested && !Self.terminal(new) ? .cancellationPending : nil
        try persist(next)
        if new == .succeeded, status.outcome == .ok { confirmedSuccesses.insert(status.command_id) }
    }

    private static func terminal(_ state: ExecutionState) -> Bool {
        state == .succeeded || state == .failed || state == .cancelled
    }
}
