import Foundation
import XCTest
import Policy
import TrustedInput
import VoiceRemoteProtocol
@testable import Router

private final class MemoryStore: TaskQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    var values: [QueuedTask] = []
    var failSave = false
    func load() throws -> [QueuedTask] { lock.lock(); defer { lock.unlock() }; return values }
    func save(_ tasks: [QueuedTask], replacing previous: [QueuedTask]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failSave, values == previous else { throw RouterError.persistence }
        values = tasks
    }
}

private final class FakeAgent: AgentAdapter, @unchecked Sendable {
    let destination: Destination
    var commands: [AuthorizedCommand] = []
    var routes: [RouteChoice] = []
    var cancellations = Set<String>()
    var throwAfterSend = false
    var throwCancel = false
    init(_ destination: Destination) { self.destination = destination }
    func dispatch(_ command: AuthorizedCommand, route: RouteChoice) throws {
        commands.append(command); routes.append(route)
        if throwAfterSend { throw RouterError.persistence }
    }
    func cancel(commandID: String, idempotencyKey: String) throws {
        if throwCancel { throw RouterError.persistence }
        cancellations.insert(idempotencyKey)
    }
}

@MainActor private final class Journal: AuditJournal {
    var bytes = Data()
    func read() throws -> Data { bytes }
    func append(_ data: Data) throws { bytes.append(data) }
}
@MainActor private final class Checkpoint: AuditCheckpointStore {
    var head = AuditCheckpoint.empty
    var pending: AuditPending?
    func load() throws -> AuditCheckpoint { head }
    func save(_ value: AuditCheckpoint) throws { head = value }
    func loadPending() throws -> AuditPending? { pending }
    func savePending(_ value: AuditPending?) throws { pending = value }
}
@MainActor private final class Authenticator: Biometric {
    func authenticate(_ challenge: AuthenticationChallenge) async throws -> AuthenticationResult {
        AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: challenge.issuedAt)
    }
}
@MainActor private final class Authority {
    var time: Int64 = 1_000_000
    let gate: PolicyGate
    let phone: PhoneInput
    private let journal = Journal(), checkpoint = Checkpoint()
    init() throws {
        let audit = try AuditLog(journal: journal, checkpoints: checkpoint, retention: AuditRetention())
        phone = PhoneInput(now: { 1_000_000 })
        gate = try PolicyGate(audit: audit, biometric: Authenticator(), clock: { 1_000_000 })
    }
    func issue(_ d: Destination, display: Bool = false, pinned: Bool = false, instruction: String = "Synthetic routing fixture") async throws -> ExecutionPermit {
        let session = phone.session(account: d.session.account, actor: "test-actor", session: "test-capture",
            device: d.id, project: d.session.workspace, destinationKind: .software)
        let input = phone.activation(session: session, kind: .inferred, expiresAt: time + 120_000)
        let tool: ToolCall = display ? .openResourceTool(OpenResourceTool(account_id: session.account,
            device_id: d.id, resource_uri: "https://example.invalid/test")) : .delegateTaskTool(DelegateTaskTool(
            account_id: session.account, device_id: d.id, project_id: session.project,
            provider_session_id: pinned ? d.session.providerSessionID : nil, instruction: instruction))
        guard case .suggestion(let preview) = gate.submit(try ProtocolCodec.encode(tool), input: input) else {
            throw RouterError.invalidAuthorization
        }
        let approval = phone.approval(session: session, requestID: input.requestID, payloadHash: preview.payloadHash)
        guard case .queued(let permit) = await gate.approve(requestID: input.requestID, evidence: approval) else {
            throw RouterError.invalidAuthorization
        }
        return permit
    }
}

private func destination(_ id: String, provider: String = "Claude", host: String? = nil,
                         cloud: Bool = false, online: Bool = true, recent: Int64 = 0) -> Destination {
    Destination(id: id, session: SessionIdentity(provider: provider, account: "test-account", host: host ?? id,
        workspace: "test-project", providerSessionID: "session-\(id)", capabilityProfile: "test-profile"),
        isCloud: cloud, capabilities: [.delegate_task, .open_resource], available: online, lastUsed: recent)
}
private func rules(_ id: String) -> RoutingRules {
    var r = RoutingRules(project: "test-project"); r.defaultTarget = id; return r
}

@MainActor final class RouterTests: XCTestCase {
    func testFiveStepPreferenceTable() {
        var r = rules("default")
        r.explicitTarget = "explicit"; r.selectedTarget = "selected"; r.activeTextField = "field"; r.mode = .dictation
        var ds = [destination("explicit"), destination("selected"), destination("field"),
                  destination("recent", recent: 20), destination("older", recent: 10), destination("default")]
        func assertTarget(_ id: String) {
            guard case .dispatch(let c) = RouteResolver.resolve(rules: r, destinations: ds) else { return XCTFail() }
            XCTAssertEqual(c.destination.id, id)
        }
        assertTarget("explicit"); r.explicitTarget = nil; assertTarget("selected")
        r.selectedTarget = nil; assertTarget("field"); r.activeTextField = nil; assertTarget("recent")
        ds[3].available = false; assertTarget("older"); ds[4].available = false; assertTarget("default")
        r.activeTextField = "field"; r.mode = .ai_control; assertTarget("default")
    }

    func testJourneyETableAndNewApprovalForCloud() async throws {
        // A fallback is a candidate for reapproval, never permission to retarget.
        let table: [(String, Bool, Bool, Bool, HoldReason?)] = [
            ("Research, laptop online", true, false, false, nil),
            ("Research, offline laptop", false, false, false, .reapprovalRequired),
            ("Show document, offline laptop", false, true, false, .machineRequired),
            ("Ambiguous, offline laptop", false, false, true, .ambiguous)
        ]
        for (name, online, display, ambiguous, hold) in table {
            let a = try Authority(), local = destination("laptop", online: online), cloud = destination("cloud", cloud: true)
            let permit = try await a.issue(local, display: display)
            var r = rules(local.id); r.selectedTarget = local.id; r.explicitProvider = "Claude"
            r.cloudCapable = !display; r.allowCloudFallback = true; r.cloudProviderOrder = ["Claude"]; r.ambiguous = ambiguous
            if display { r.capability = .open_resource; r.machineDependency = "laptop" }
            let router = try TaskRouter(store: MemoryStore(), policy: a.gate)
            try router.enqueue(permit, rules: r, destinations: display ? [local] : [local, cloud])
            let localAgent = FakeAgent(local), remote = FakeAgent(cloud)
            try router.reconnect(targets: [localAgent, remote])
            let task = try XCTUnwrap(router.snapshot().first)
            XCTAssertEqual(task.hold, hold, name); XCTAssertNotEqual(task.state, .succeeded, name)
            XCTAssertEqual(remote.commands.count, 0, name)
            XCTAssertEqual(localAgent.commands.count, online ? 1 : 0, name)
            if online { XCTAssertEqual(localAgent.commands.first, permit.command) }
            if hold != nil { XCTAssertTrue(task.visibleStatus.contains("Held")) }
        }
        let a = try Authority(), cloud = destination("cloud", cloud: true), remote = FakeAgent(destination("cloud", cloud: true))
        var r = rules(cloud.id); r.explicitTarget = cloud.id; r.cloudCapable = true
        let permit = try await a.issue(cloud)
        let router = try TaskRouter(store: MemoryStore(), policy: a.gate)
        try router.enqueue(permit, rules: r, destinations: [cloud]); try router.reconnect(targets: [remote])
        XCTAssertEqual(remote.commands.first, permit.command)
        XCTAssertTrue(try XCTUnwrap(remote.routes.first).label.contains("Cloud fallback · new execution"))
    }

    func testReviewApprovedDestinationAndPinnedSessionAreBinding() async throws {
        for pinned in [false, true] {
            let a = try Authority(), local = destination("laptop", online: !pinned), other = destination("cloud", cloud: true)
            let permit = try await a.issue(local, pinned: pinned)
            var r = rules(local.id); r.selectedTarget = pinned ? local.id : other.id
            r.cloudCapable = true; r.allowCloudFallback = true; r.cloudProviderOrder = ["Claude"]
            let router = try TaskRouter(store: MemoryStore(), policy: a.gate), fake = FakeAgent(other)
            try router.enqueue(permit, rules: r, destinations: [local, other])
            try router.reconnect(targets: [FakeAgent(local), fake])
            XCTAssertEqual(fake.commands.count, 0)
            XCTAssertEqual(router.snapshot().first?.hold, .reapprovalRequired)
            XCTAssertEqual(router.snapshot().first?.command, permit.command)
        }
        // Same destination ID but a different provider session is also forbidden.
        let a = try Authority(), d = destination("laptop"), otherSession = destination("laptop", provider: "Codex")
        let permit = try await a.issue(d, pinned: true)
        var body = otherSession
        body = Destination(id: d.id, session: SessionIdentity(provider: "Codex", account: "test-account", host: "laptop",
            workspace: "test-project", providerSessionID: "other-session", capabilityProfile: "test-profile"),
            capabilities: d.capabilities, available: true)
        let router = try TaskRouter(store: MemoryStore(), policy: a.gate)
        XCTAssertThrowsError(try router.enqueue(permit, rules: rules(d.id), destinations: [body]))
    }

    func testReviewCloudDisabledAndAmbiguousOfflineDefault() {
        var r = rules("laptop"); r.explicitProvider = "Claude"; r.cloudCapable = true
        guard case .dispatch(let choice) = RouteResolver.resolve(rules: r, destinations: [destination("cloud", cloud: true), destination("local")]) else { return XCTFail() }
        XCTAssertEqual(choice.destination.id, "local")
        r.explicitProvider = nil; r.ambiguous = true; r.allowCloudFallback = true
        XCTAssertEqual(RouteResolver.resolve(rules: r, destinations: [destination("laptop", online: false), destination("cloud", cloud: true, recent: 10)]), .hold(.ambiguous))
        r.ambiguous = false
        guard case .dispatch(let cloud) = RouteResolver.resolve(rules: r, destinations: [destination("cloud", cloud: true, recent: 10)]) else { return XCTFail() }
        XCTAssertTrue(cloud.label.contains("Cloud"))
    }

    func testReviewExplicitProviderAndHostNeverSwitch() {
        var r = rules("laptop"); r.selectedTarget = "laptop"; r.explicitProvider = "Claude"
        r.localProviderOrder = ["Codex"]; r.cloudProviderOrder = ["Codex"]; r.cloudCapable = true; r.allowCloudFallback = true
        let ds = [destination("laptop", online: false), destination("codex", provider: "Codex", host: "laptop"), destination("cloud", provider: "Codex", cloud: true)]
        XCTAssertEqual(RouteResolver.resolve(rules: r, destinations: ds), .hold(.unavailable))
        r.explicitProvider = nil; r.explicitHost = "laptop"
        guard case .dispatch(let choice) = RouteResolver.resolve(rules: r, destinations: ds) else { return XCTFail() }
        XCTAssertEqual(choice.destination.id, "codex")
        r.explicitProvider = "Claude"
        XCTAssertEqual(RouteResolver.resolve(rules: r, destinations: ds), .hold(.unavailable))
    }

    func testReviewForgedStoredPayloadHashDestinationAndAuthorityAreRejected() async throws {
        let a = try Authority(), d = destination("laptop"), store = MemoryStore()
        let permit = try await a.issue(d)
        let router = try TaskRouter(store: store, policy: a.gate)
        try router.enqueue(permit, rules: rules(d.id), destinations: [d])
        let original = try XCTUnwrap(store.values.first)
        XCTAssertEqual(PayloadDigest.sha256(original.immutablePreview), permit.command.payload_hash)
        for field in ["payload", "hash", "destination", "authority", "preview"] {
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            var command = try XCTUnwrap(record["command"] as? [String: Any])
            switch field {
            case "payload":
                var tool = try XCTUnwrap(command["immutable_task_payload"] as? [String: Any]); tool["instruction"] = "Altered synthetic payload"; command["immutable_task_payload"] = tool
            case "hash": command["payload_hash"] = String(repeating: "a", count: 64)
            case "destination": command["destination_id"] = "other"
            case "authority": command["granted_scope_id"] = "forged"
            default: record["immutablePreview"] = Data("forged".utf8).base64EncodedString()
            }
            record["command"] = command
            let forged = try JSONDecoder().decode(QueuedTask.self, from: JSONSerialization.data(withJSONObject: record))
            let injected = MemoryStore(); injected.values = [forged]
            let restored = try TaskRouter(store: injected, policy: a.gate), fake = FakeAgent(d)
            try restored.reconnect(targets: [fake]); XCTAssertEqual(fake.commands.count, 0, field)
            XCTAssertEqual(restored.snapshot().first?.hold, .reapprovalRequired)
        }
        let unrelatedAuthority = try Authority()
        let restored = try TaskRouter(store: store, policy: unrelatedAuthority.gate), fake = FakeAgent(d)
        try restored.reconnect(targets: [fake]); XCTAssertEqual(fake.commands.count, 0)
        XCTAssertEqual(restored.snapshot().first?.hold, .reapprovalRequired)
    }

    func testReconnectRestartDispatchOnceAndCancelHeld() async throws {
        let a = try Authority(), local = destination("laptop", online: false), store = MemoryStore()
        let permit = try await a.issue(local)
        let router = try TaskRouter(store: store, policy: a.gate)
        try router.enqueue(permit, rules: rules(local.id), destinations: [local]); try router.reconnect(targets: [])
        var live = local; live.available = true
        let fake = FakeAgent(live), restored = try TaskRouter(store: store, policy: a.gate)
        try restored.reconnect(targets: [fake]); try restored.reconnect(targets: [fake])
        try restored.enqueue(permit, rules: rules(local.id), destinations: [local])
        let restarted = try TaskRouter(store: store, policy: a.gate); try restarted.reconnect(targets: [fake])
        XCTAssertEqual(fake.commands, [permit.command]); XCTAssertEqual(restarted.snapshot().first?.state, .dispatched)
        let held = try TaskRouter(store: MemoryStore(), policy: a.gate)
        try held.enqueue(permit, rules: rules(local.id), destinations: [local]); try held.reconnect(targets: [])
        try held.cancel(accountID: permit.command.account_id, commandID: permit.command.command_id, targets: [])
        try held.reconnect(targets: [fake]); XCTAssertEqual(held.snapshot().first?.state, .cancelled)
        XCTAssertEqual(fake.commands.count, 1)
    }

    func testReviewThrowingCancelDoesNotBlockUnrelatedTask() async throws {
        let a = try Authority(), one = destination("one"), two = destination("two"), store = MemoryStore()
        let first = try await a.issue(one), second = try await a.issue(two)
        let router = try TaskRouter(store: store, policy: a.gate), bad = FakeAgent(one), good = FakeAgent(two)
        try router.enqueue(first, rules: rules(one.id), destinations: [one]); try router.reconnect(targets: [bad])
        try router.cancel(accountID: first.command.account_id, commandID: first.command.command_id, targets: [])
        try router.enqueue(second, rules: rules(two.id), destinations: [two]); bad.throwCancel = true
        try router.reconnect(targets: [bad, good])
        XCTAssertEqual(good.commands, [second.command]); XCTAssertEqual(router.snapshot().first?.hold, .cancellationPending)
        bad.throwCancel = false
        try router.reconnect(targets: [bad, good]); try router.reconnect(targets: [bad, good])
        XCTAssertEqual(bad.cancellations.count, 1); XCTAssertEqual(bad.commands.count, 1)
    }

    func testReviewSkewedTerminalStatusAndNoFakeSuccess() async throws {
        let a = try Authority(), d = destination("laptop"), permit = try await a.issue(d)
        let router = try TaskRouter(store: MemoryStore(), policy: a.gate), fake = FakeAgent(d)
        try router.enqueue(permit, rules: rules(d.id), destinations: [d])
        func status(_ state: ExecutionState, _ time: Int64, _ outcome: TaskStatusOutcome? = nil) -> TaskStatus {
            TaskStatus(account_id: permit.command.account_id, command_id: permit.command.command_id,
                       execution_state: state, updated_at: time, outcome: outcome)
        }
        XCTAssertThrowsError(try router.receive(status(.succeeded, 0, .ok), from: d.session))
        try router.reconnect(targets: [fake]); XCTAssertEqual(router.snapshot().first?.state, .dispatched)
        XCTAssertThrowsError(try router.receive(status(.succeeded, 0, .ok), from: destination("other").session))
        XCTAssertThrowsError(try router.receive(status(.succeeded, 0), from: d.session))
        try router.receive(status(.running, 9_000_000), from: d.session)
        XCTAssertThrowsError(try router.receive(status(.dispatched, 9_000_001), from: d.session))
        try router.receive(status(.succeeded, 0, .ok), from: d.session)
        XCTAssertEqual(router.snapshot().first?.state, .succeeded)
        XCTAssertThrowsError(try router.receive(status(.running, 9_000_002), from: d.session))
    }

    func testDeliveryFailureAndStaleStoreNeverRedispatch() async throws {
        let a = try Authority(), d = destination("laptop"), store = MemoryStore(), permit = try await a.issue(d)
        let router = try TaskRouter(store: store, policy: a.gate)
        try router.enqueue(permit, rules: rules(d.id), destinations: [d])
        let stale = try TaskRouter(store: store, policy: a.gate), fake = FakeAgent(d); fake.throwAfterSend = true
        try router.reconnect(targets: [fake])
        XCTAssertThrowsError(try stale.reconnect(targets: [fake]))
        let restored = try TaskRouter(store: store, policy: a.gate); try restored.reconnect(targets: [fake])
        XCTAssertEqual(fake.commands, [permit.command]); XCTAssertEqual(restored.snapshot().first?.hold, .deliveryUnknown)
    }

    func testDiskRoundTripAndFailedPersistencePreventDispatch() async throws {
        let a = try Authority(), d = destination("laptop"), permit = try await a.issue(d)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.json"), fake = FakeAgent(d)
        do {
            let store = try FileTaskQueueStore(url: url), router = try TaskRouter(store: store, policy: a.gate)
            XCTAssertThrowsError(try FileTaskQueueStore(url: url))
            try router.enqueue(permit, rules: rules(d.id), destinations: [d]); try router.reconnect(targets: [fake])
        }
        do {
            let store = try FileTaskQueueStore(url: url), restored = try TaskRouter(store: store, policy: a.gate)
            try restored.reconnect(targets: [fake]); XCTAssertEqual(fake.commands, [permit.command])
        }
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try TaskRouter(store: FileTaskQueueStore(url: url), policy: a.gate))
        let store = MemoryStore(), blocked = try TaskRouter(store: store, policy: a.gate)
        try blocked.enqueue(permit, rules: rules(d.id), destinations: [d]); store.failSave = true
        XCTAssertThrowsError(try blocked.reconnect(targets: [fake])); XCTAssertEqual(fake.commands.count, 1)
    }
    func testReviewSelectedDestinationOutsideRegistryRequiresReapproval() async throws {
        let a = try Authority(), d = destination("approved"), permit = try await a.issue(d)
        let router = try TaskRouter(store: MemoryStore(), policy: a.gate), fake = FakeAgent(d)
        var r = rules(d.id); r.selectedTarget = "other-offline-target"
        try router.enqueue(permit, rules: r, destinations: [d]); try router.reconnect(targets: [fake])
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(router.snapshot().first?.hold, .reapprovalRequired)
    }

}
