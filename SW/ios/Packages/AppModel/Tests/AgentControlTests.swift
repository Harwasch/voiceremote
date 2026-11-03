import Foundation
import Core
import Stt
import Brain
import Testing
import Policy
import TrustedInput
import Router
import VoiceRemoteProtocol
@testable import AppModel

private actor AgentMessages {
    var values: [InnerMessage] = []
    func send(_ value: InnerMessage) { values.append(value) }
    func request() throws -> String {
        for value in values.reversed() { if case .agentInventoryRequest(let request) = value { return request.request_id } }
        throw RouterError.invalidStatus
    }
}

@Test @MainActor func sleepingPhoneReconcilesWithoutExecutingPreviouslyQueuedWork() async throws {
    let rig = try AgentRig(); try await rig.install()
    rig.control.disconnected("pc", epoch: rig.epoch)
    let permit = try await rig.permit()
    _ = try rig.control.enqueue(permit)
    // Wake must invalidate the old execution opportunity before fresh inventory.
    try rig.control.prepareForWake()
    try await rig.connect()
    try rig.control.receive(await rig.inventory(), from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot()[0].state == .queued)
    #expect(rig.router.snapshot()[0].hold == .reapprovalRequired)
}

@Test @MainActor func wakeReconciliationWaitsForCurrentExecutorOutcomeAndTimeoutKeepsUnconfirmedState() async throws {
    let rig = try AgentRig(); try await rig.install()
    let permit = try await rig.permit()
    _ = try rig.control.enqueue(permit)
    do {
        try await rig.control.reconcileTasks(on: "pc", epoch: rig.epoch, timeout: .milliseconds(1))
        Issue.record("A socket write was mistaken for an executor outcome")
    } catch { #expect(rig.router.snapshot()[0].state == .dispatched) }
    let query = Task { try await rig.control.reconcileTasks(on: "pc", epoch: rig.epoch) }
    for _ in 0..<30 { await Task.yield() }
    let status = TaskStatus(account_id: "fixture", command_id: permit.command.command_id, execution_state: .dispatched,
        updated_at: 1_000_001, outcome: .dispatched)
    try rig.control.receive(status, from: "pc", epoch: UUID())
    #expect(rig.router.snapshot()[0].state == .dispatched)
    try rig.control.receive(status, from: "pc", epoch: rig.epoch)
    try await query.value
    #expect(rig.router.snapshot()[0].state == .dispatched)
    for _ in 0..<20 { await Task.yield() }
    #expect(await rig.messages.values.filter { if case .agentDispatch = $0 { true } else { false } }.count == 1)
}
private final class AgentQueue: TaskQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    var tasks: [QueuedTask] = []
    func load() -> [QueuedTask] { lock.withLock { tasks } }
    func save(_ value: [QueuedTask], replacing previous: [QueuedTask]) throws {
        try lock.withLock { guard tasks == previous else { throw RouterError.persistence }; tasks = value }
    }
}
@MainActor private final class AgentRig {
    let gate: PolicyGate
    let store: any TaskQueueStore
    let router: TaskRouter
    let control: AgentControl
    let messages = AgentMessages()
    let epoch = UUID()
    let device = DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Synthetic PC", platform: .windows,
        role: .both, capabilities: [.delegate_task, .cancel_task, .open_resource])
    let wire = AgentSession(account_id: "fixture", device_id: "pc", project_id: "arm", workspace: "C:\\synthetic\\arm", provider: .codex,
        provider_session_id: "named-session", capability_profile: .read_only, capabilities: [.delegate_task, .cancel_task, .open_resource])
    init(store: any TaskQueueStore = AgentQueue(), now: @escaping @MainActor () -> Int64 = { 1_000_000 }) throws {
        self.store = store
        gate = try PolicyGate(audit: AuditLog(journal: Journal(), checkpoints: Checkpoint(), retention: AuditRetention()), biometric: Bio(), clock: now)
        router = try TaskRouter(store: store, policy: gate)
        control = AgentControl(router: router, policy: gate, account: "fixture", actor: "owner", now: now)
    }
    func connect() async throws {
        let messages = messages
        try await control.connected(device, epoch: epoch) { await messages.send($0) }
    }
    func inventory(actor: String = "owner", session: AgentSession? = nil) async throws -> AgentInventory {
        AgentInventory(account_id: "fixture", device_id: "pc", request_id: try await messages.request(),
            authenticated_actor: actor, sessions: [session ?? wire])
    }
    func install() async throws { try await connect(); try control.receive(await inventory(), from: "pc", epoch: epoch) }
    func permit(instruction: String = "Synthetic task") async throws -> ExecutionPermit {
        let input = PhoneInput(now: { 1_000_000 })
        let session = input.session(account: "fixture", actor: "owner", session: UUID().uuidString, device: "pc", project: "arm", destinationKind: .software)
        let activation = input.activation(session: session, kind: .inferred, expiresAt: 1_120_000)
        let tool = ToolCall.delegateTaskTool(DelegateTaskTool(account_id: "fixture", device_id: "pc", project_id: "arm", provider_session_id: "named-session", instruction: instruction))
        guard case .suggestion(let preview) = gate.submit(try ProtocolCodec.encode(tool), input: activation),
              case .queued(let permit) = await gate.approve(requestID: activation.requestID,
                evidence: input.approval(session: session, requestID: preview.requestID, payloadHash: preview.payloadHash)) else { throw RouterError.invalidAuthorization }
        return permit
    }
}

@Test @MainActor func agentInventoryRequiresExactActorConnectionRequestAndEnrolledCapabilities() async throws {
    let rig = try AgentRig(); try await rig.connect()
    #expect(throws: (any Error).self) { try rig.control.receive(AgentInventory(account_id: "fixture", device_id: "pc", request_id: "forged", authenticated_actor: "owner", sessions: [rig.wire]), from: "pc", epoch: rig.epoch) }
    let wrongActor = try await rig.inventory(actor: "forged")
    #expect(throws: (any Error).self) { try rig.control.receive(wrongActor, from: "pc", epoch: rig.epoch) }
    let good = try await rig.inventory()
    #expect(throws: (any Error).self) { try rig.control.receive(good, from: "pc", epoch: UUID()) }
    #expect(throws: (any Error).self) { try rig.control.receive(good, from: "other-pc", epoch: rig.epoch) }
    #expect(rig.control.destinations.isEmpty)
    try rig.control.receive(good, from: "pc", epoch: rig.epoch)
    #expect(rig.control.destinations.first?.session.workspace == "arm")
    #expect(rig.control.destinations.first?.session.executionWorkspace == "C:\\synthetic\\arm")
    let noCapability = DeviceInfo(account_id: "fixture", device_id: "other", display_name: "Synthetic", platform: .linux, role: .agent, capabilities: [])
    let messages = AgentMessages()
    try await rig.control.connected(noCapability, epoch: UUID()) { await messages.send($0) }
    #expect(await messages.values.isEmpty)
}

@Test @MainActor func pairedAgentPinsIdentityHoldsOfflineAndRejectsUnsolicitedStatus() async throws {
    let rig = try AgentRig(); try await rig.install()
    let permit = try await rig.permit()
    rig.control.disconnected("pc", epoch: rig.epoch)
    _ = try rig.control.enqueue(permit)
    #expect(rig.router.snapshot()[0].hold == .machineRequired)
    #expect(rig.router.snapshot()[0].state == .queued)
    try await rig.connect()
    try rig.control.receive(await rig.inventory(), from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot()[0].state == .dispatched)
    let status = TaskStatus(account_id: "fixture", command_id: permit.command.command_id, execution_state: .dispatched, updated_at: 1_000_001, outcome: .dispatched)
    try rig.control.receive(status, from: "pc", epoch: UUID())
    #expect(rig.router.snapshot()[0].state == .dispatched)
    try rig.control.receive(status, from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot()[0].state == .dispatched)
    for _ in 0..<20 { await Task.yield() }
    let dispatches = await rig.messages.values.filter { if case .agentDispatch = $0 { true } else { false } }
    #expect(dispatches.count == 1)
    if case .agentDispatch(let envelope) = dispatches.first {
        #expect(envelope.session == rig.wire)
        #expect(envelope.immutable_preview == permit.immutablePreview.base64EncodedString())
        #expect(envelope.expires_at == permit.expiresAt)
    }
}

@Test @MainActor func changedProviderProfileCannotReleasePreviouslyApprovedHold() async throws {
    let rig = try AgentRig(); try await rig.install()
    rig.control.disconnected("pc", epoch: rig.epoch)
    _ = try rig.control.enqueue(await rig.permit())
    try await rig.connect()
    let replacement = AgentSession(account_id: "fixture", device_id: "pc", project_id: "arm", workspace: rig.wire.workspace,
        provider: .codex, provider_session_id: "named-session", capability_profile: .workspace_write, capabilities: rig.wire.capabilities)
    try rig.control.receive(await rig.inventory(session: replacement), from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot()[0].state == .queued)
    for _ in 0..<20 { await Task.yield() }
    #expect(await rig.messages.values.allSatisfy { if case .agentDispatch = $0 { false } else { true } })
}

@Test @MainActor func linkedQueueNeedsActualAuthorizedPredecessorSuccessAndRestoredQueueNeedsReview() async throws {
    let rig = try AgentRig(); try await rig.install()
    let first = try await rig.permit(instruction: "Synthetic predecessor")
    let second = try await rig.permit(instruction: "Synthetic successor")
    _ = try rig.control.enqueue(first)
    _ = try rig.control.enqueue(second, dependencies: [first.command.command_id])
    #expect(rig.router.snapshot()[1].hold == .predecessorRequired)
    let failed = TaskStatus(account_id: "fixture", command_id: first.command.command_id, execution_state: .failed, updated_at: 1_000_001, outcome: .denied)
    try rig.control.receive(failed, from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot()[1].state == .queued)
    #expect(rig.router.snapshot()[1].hold == .predecessorRequired)
    let newGate = try PolicyGate(audit: AuditLog(journal: Journal(), checkpoints: Checkpoint(), retention: AuditRetention()), biometric: Bio(), clock: { 1_000_000 })
    let restored = try TaskRouter(store: rig.store, policy: newGate)
    #expect(restored.snapshot()[1].hold == .reapprovalRequired)
    try restored.reconnect(targets: [])
    #expect(restored.snapshot()[1].state == .queued)
}

@Test @MainActor func revokedComputerCannotResumeItsOldQueuedPermitAfterRePair() async throws {
    let rig = try AgentRig(); try await rig.install()
    rig.control.disconnected("pc", epoch: rig.epoch)
    _ = try rig.control.enqueue(await rig.permit())
    rig.control.revoked("pc")
    try await rig.connect()
    try rig.control.receive(await rig.inventory(), from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot()[0].state == .queued)
    #expect(rig.router.snapshot()[0].hold == .reapprovalRequired)
}

@Test @MainActor func playbackWakeWithScopedGrantStaysInferredAndGrantCanBeRevoked() async throws {
    let rig = try Rig(script: [.final("Assistant switch to phone")])
    rig.model.setTarget(.device("phone"))
    let phone = try #require(rig.model.destination)
    rig.model.grantTargetSelection(device: phone, project: "default")
    let grant = try #require(rig.model.grants.first)
    rig.model.wakeArmed = true
    try await rig.record(mode: .ai_control)
    #expect(rig.model.controls.target == .device("phone"))
    await rig.model.review(try #require(rig.model.suggestions.first))
    // Ambiguous wake is tier 1 even while armed and holding a matching grant.
    #expect(rig.model.approval != nil)
    #expect(rig.execution.permits.isEmpty)
    rig.model.revokeGrant(grant)
    #expect(rig.model.grants.isEmpty)
    rig.model.dismissApproval()
}

@MainActor private final class GrantTime { var value: Int64 = 1_000_000 }
@Test @MainActor func expiredScopedGrantRequiresPhoneReviewForTrustedPTT() async throws {
    let time = GrantTime(), capture = Capture(), target = TargetSpy(), brain = BrainSpy()
    let gate = try PolicyGate(audit: AuditLog(journal: Journal(), checkpoints: Checkpoint(), retention: AuditRetention()), biometric: Bio(), clock: { time.value })
    let model = VoiceAppModel(accountID: "fixture", phoneID: "phone", actorID: "owner",
        registry: DeviceRegistry(accountID: "fixture", revocation: target), history: try AppHistoryStore(now: time.value, accountID: "fixture"), target: target,
        policy: gate, makeCapture: { capture }, engines: { [FakeEngine(script: [.final("switch to phone")])] },
        brain: { _ in brain }, now: { time.value }, deliver: { _ in Issue.record("Expired grant executed"); return [] })
    model.setTarget(.device("phone"))
    model.grantTargetSelection(device: try #require(model.destination), project: "default")
    time.value = try #require(model.grants.first).expiresAt + 1
    model.setMode(.ai_control); model.setCapture(.hold); model.press(at: 1000); model.advanceTrigger(to: 1300)
    for _ in 0..<2000 { if model.isRecording { break }; try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.isRecording)
    capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500], timestamp: 0)))
    model.finishUtterance()
    for _ in 0..<2000 { if model.listening == .idle { break }; try await Task.sleep(for: .milliseconds(1)) }
    await model.review(try #require(model.suggestions.first))
    #expect(model.approval != nil)
}

@Test @MainActor func approvalRouteCannotChangeBeforeQueueing() async throws {
    let rig = try AgentRig(); try await rig.install()
    let permit = try await rig.permit()
    let route = try #require(rig.control.destinations.first)
    let changed = Destination(id: route.id, session: SessionIdentity(provider: "claude", account: "fixture", host: "pc",
        workspace: "arm", providerSessionID: "named-session", capabilityProfile: "read_only"), capabilities: route.capabilities, available: true)
    #expect(throws: (any Error).self) { try rig.control.enqueue(permit, expectedRoute: changed) }
    #expect(rig.router.snapshot().isEmpty)
    _ = try rig.control.enqueue(permit, expectedRoute: route)
    #expect(rig.router.snapshot()[0].state == .dispatched)
}

@MainActor private final class ExplicitPairingChoice: ComputerPairing {
    var choices: [Bool] = []
    func begin(_ invitationOrCode: String, role: DeviceInfoRole) async throws -> String { "synthetic phrase" }
    func begin(_ invitationOrCode: String, role: DeviceInfoRole, allowAgentCommands: Bool) async throws -> String {
        choices.append(allowAgentCommands); return "synthetic phrase"
    }
    func confirm(_ phrase: String) async throws -> DeviceInfo { throw RouterError.invalidAuthorization }
    func cancel() async {}
}
@Test @MainActor func agentRoleAloneDoesNotEnablePhoneCommandCapability() async {
    let backend = ExplicitPairingChoice(), flow = PairingFlow(backend: ExplicitPairingChoice())
    let explicit = PairingFlow(backend: backend)
    explicit.role = .agent
    await explicit.begin("synthetic invitation")
    #expect(backend.choices == [false])
    explicit.allowAgentCommands = true
    await explicit.begin("synthetic invitation")
    #expect(backend.choices == [false, true])
    #expect(!flow.allowAgentCommands)
}

@Test @MainActor func approvedCancelToolUsesFreshPermitAndCannotReviveOriginalExecution() async throws {
    let rig = try AgentRig(); try await rig.install()
    let original = try await rig.permit()
    _ = try rig.control.enqueue(original)
    let input = PhoneInput(now: { 1_000_000 })
    let scope = input.session(account: "fixture", actor: "owner", session: "cancel-input", device: "pc", project: "arm", destinationKind: .software)
    let activation = input.activation(session: scope, kind: .inferred, expiresAt: 1_030_000)
    let tool = ToolCall.cancelTaskTool(CancelTaskTool(account_id: "fixture", command_id: original.command.command_id))
    guard case .suggestion(let preview) = rig.gate.submit(try ProtocolCodec.encode(tool), input: activation),
          case .queued(let permit) = await rig.gate.approve(requestID: activation.requestID,
            evidence: input.approval(session: scope, requestID: preview.requestID, payloadHash: preview.payloadHash)) else {
        Issue.record("Cancellation required a fresh approval"); return
    }
    _ = try rig.control.enqueue(permit)
    #expect(rig.router.snapshot().count == 1)
    #expect(rig.router.snapshot()[0].cancellationRequested)
    #expect(rig.router.snapshot()[0].hold == .cancellationPending)
}


private final class AgentRetentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Int64 = 1_000_000
    func read() -> Int64 { lock.withLock { time } }
    func expire() { lock.withLock { time += 604_800_000 } }
}
@Test @MainActor func agentControlUsesRetainedTaskStoreWithoutRestoringExpiredPayloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("tasks.json"), clock = AgentRetentionClock()
    let store = try RetainedTaskStore(url: url, accountID: "fixture", now: { clock.read() })
    let rig = try AgentRig(store: store, now: { clock.read() })
    try await rig.install()
    rig.control.disconnected("pc", epoch: rig.epoch)
    let permit = try await rig.permit(instruction: "Synthetic retained agent payload")
    _ = try rig.control.enqueue(permit)
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Synthetic retained agent payload"))
    let expiredTask = try #require(rig.router.snapshot().first)
    clock.expire(); try store.maintain()
    #expect(rig.router.snapshot().isEmpty)
    try await rig.connect()
    try rig.control.receive(await rig.inventory(), from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot().isEmpty)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Synthetic retained agent payload"))
    #expect(try store.load().isEmpty)
    #expect(throws: (any Error).self) { try store.save([expiredTask], replacing: []) }
    for _ in 0..<20 { await Task.yield() }
    #expect(await rig.messages.values.allSatisfy { if case .agentDispatch = $0 { false } else { true } })
}

@Test @MainActor func cancellationUsesLiveStateRatherThanHeldCardSnapshot() async throws {
    let rig = try AgentRig(); try await rig.install()
    rig.control.disconnected("pc", epoch: rig.epoch)
    _ = try rig.control.enqueue(await rig.permit())
    let stale = try #require(rig.router.snapshot().first)
    #expect(stale.state == .queued)
    try await rig.connect(); try rig.control.receive(await rig.inventory(), from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot().first?.state == .dispatched)
    try await rig.control.cancel(stale)
    #expect(await rig.messages.values.contains { if case .authorizedCommand(let command) = $0,
        case .cancelTaskTool = command.immutable_task_payload { true } else { false } })
}

@Test @MainActor func modelCannotChooseDelegateSessionWhenUserHasNotSelectedOne() async throws {
    let agent = try AgentRig(); try await agent.install()
    let rig = try Rig(tool: .delegateTaskTool(DelegateTaskTool(account_id: "fixture", device_id: "pc",
        project_id: "arm", provider_session_id: "named-session", instruction: "Synthetic task")), agent: agent.control, policy: agent.gate)
    try await rig.registry.register(agent.device); await rig.model.refresh()
    try await rig.record(mode: .ai_control)
    await rig.model.review(try #require(rig.model.suggestions.first))
    #expect(rig.model.approval == nil)
    #expect(agent.router.snapshot().isEmpty)
}

@Test @MainActor func dismissedReviewCannotEnqueueUsingStillOpenApproval() async throws {
    for sensitive in [false, true] {
        let rig = try Rig(sensitive: sensitive)
        let original = rig.model.controls.target
        try await rig.record(mode: .ai_control)
        let card = try #require(rig.model.suggestions.first)
        await rig.model.review(card)
        #expect(rig.model.approval != nil)
        await rig.model.dismiss(card)
        await rig.model.approve()
        #expect(rig.execution.permits.isEmpty)
        #expect(rig.model.controls.target == original)
    }
}

@Test @MainActor func appDispatchReplyNeverReleasesLinkedSuccessor() async throws {
    let rig = try AgentRig(); try await rig.install()
    let first = try await rig.permit(), second = try await rig.permit(instruction: "Synthetic successor")
    _ = try rig.control.enqueue(first)
    _ = try rig.control.enqueue(second, dependencies: [first.command.command_id])
    try rig.control.receive(TaskStatus(account_id: "fixture", command_id: first.command.command_id,
        execution_state: .running, updated_at: 1_000_001), from: "pc", epoch: rig.epoch)
    try rig.control.receive(TaskStatus(account_id: "fixture", command_id: first.command.command_id,
        execution_state: .dispatched, updated_at: 1_000_002, outcome: .dispatched, app_reply: "Synthetic refusal"), from: "pc", epoch: rig.epoch)
    #expect(rig.router.snapshot()[0].appReply == "Synthetic refusal")
    #expect(rig.router.snapshot()[1].state == .queued)
    #expect(rig.router.snapshot()[1].hold == .predecessorRequired)
}

@MainActor private final class ReviewUtterance {
    var capture = Capture()
    var text = "Prepare synthetic note. Then prepare another note."
}
@Test @MainActor func spokenCancelInvalidatesTheStillOpenApprovalSheet() async throws {
    let utterance = ReviewUtterance()
    let rig = try Rig(sensitive: true, captureFactory: { utterance.capture = Capture(); return utterance.capture },
        scriptProvider: { [.final(utterance.text)] }, additionalTool: .prepareSendTool(PrepareSendTool(
            account_id: "fixture", device_id: "phone", recipient: "fixture-recipient", content: "Synthetic second note")))
    rig.model.setMode(.ai_control)
    func speak() async throws {
        rig.model.setCapture(.continuous)
        try await rig.until { rig.model.isRecording }
        utterance.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500], timestamp: 0)))
        rig.model.finishUtterance()
        try await rig.until { rig.model.listening == .idle }
    }
    try await speak()
    #expect(rig.model.suggestions.count == 2)
    await rig.model.review(try #require(rig.model.suggestions.first))
    let review = try #require(rig.model.approval?.id)
    utterance.text = "cancel the first one"
    try await speak()
    #expect(rig.model.approval?.id == review)
    await rig.model.approve()
    #expect(rig.execution.permits.isEmpty)
}

@Test @MainActor func providerReplyUsesTheOriginalRetainedTaskExpiry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("tasks.json"), clock = AgentRetentionClock()
    let store = try RetainedTaskStore(url: url, accountID: "fixture", now: { clock.read() })
    let rig = try AgentRig(store: store, now: { clock.read() }); try await rig.install()
    let permit = try await rig.permit()
    _ = try rig.control.enqueue(permit)
    try rig.control.receive(TaskStatus(account_id: "fixture", command_id: permit.command.command_id,
        execution_state: .dispatched, updated_at: clock.read(), outcome: .dispatched, app_reply: "Synthetic expiring reply"), from: "pc", epoch: rig.epoch)
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Synthetic expiring reply"))
    clock.expire(); try store.maintain()
    #expect(rig.router.snapshot().isEmpty)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Synthetic expiring reply"))
}

@MainActor private extension AgentRig {
    func delivered(_ command: AuthorizedCommand, reply: String = "Synthetic exit zero; effect unverified") throws {
        try control.receive(TaskStatus(account_id: "fixture", command_id: command.command_id,
            execution_state: .dispatched, updated_at: 1_000_000, outcome: .dispatched, app_reply: reply), from: "pc", epoch: epoch)
    }
    func attest(_ task: QueuedTask, epoch: UUID? = nil, hash: String? = nil) throws {
        let actualEpoch = epoch ?? self.epoch
        let input = PhoneInput(now: { 1_000_000 })
        let session = input.session(account: "fixture", actor: "owner", session: actualEpoch.uuidString,
            device: task.command.destination_id, project: task.rules.project, destinationKind: .software)
        try control.confirmOwnerCompletion(task, epoch: actualEpoch, evidence: input.ownerCompletion(session: session,
            commandID: task.command.command_id, operationHash: try hash ?? TaskRouter.completionOperation(task)))
    }
}

@Test @MainActor func ownerObservedEffectReleasesExactlyOneApprovedSuccessorAndAuditsCompletion() async throws {
    let rig = try AgentRig(); try await rig.install()
    let first = try await rig.permit(instruction: "Create the synthetic result file"), second = try await rig.permit(instruction: "Read the synthetic result file")
    _ = try rig.control.enqueue(first); _ = try rig.control.enqueue(second, dependencies: [first.command.command_id])
    #expect(rig.router.snapshot()[1].hold == .predecessorRequired)
    #expect(rig.control.completionEpoch(for: rig.router.snapshot()[0]) == nil)
    try rig.delivered(first.command)
    let task = rig.router.snapshot()[0]
    #expect(task.visibleStatus.contains("waiting"))
    #expect(rig.router.snapshot()[1].state == .queued)
    #expect(throws: (any Error).self) { try rig.attest(task, hash: String(repeating: "f", count: 64)) }
    #expect(throws: (any Error).self) { try rig.attest(task, epoch: UUID()) }
    // Independent postcondition for this scoped synthetic operation. The phone
    // owner sees this result; no CLI reply or return code stands in for it.
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: output) }
    try Data("synthetic-result".utf8).write(to: output)
    #expect(try Data(contentsOf: output) == Data("synthetic-result".utf8))
    try rig.attest(task)
    #expect(rig.router.snapshot()[0].ownerConfirmed == true)
    #expect(rig.router.snapshot()[1].state == .dispatched)
    #expect(rig.gate.hasOwnerCompletion(commandID: task.command.command_id, operationHash: try TaskRouter.completionOperation(task)))
    #expect(throws: (any Error).self) { try rig.attest(task) }
    try rig.control.reconnect()
    for _ in 0..<30 { await Task.yield() }
    #expect(await rig.messages.values.filter { if case .agentDispatch = $0 { true } else { false } }.count == 2)
}

@Test @MainActor func refusalExitZeroCancellationWrongSessionAndReconnectNeverConfirmEffect() async throws {
    for scenario in ["refusal", "reply", "exit-zero", "cancel", "reconnect", "forged-success"] {
        let rig = try AgentRig(); try await rig.install()
        let first = try await rig.permit(), second = try await rig.permit(instruction: "Synthetic successor")
        _ = try rig.control.enqueue(first); _ = try rig.control.enqueue(second, dependencies: [first.command.command_id])
        try rig.delivered(first.command, reply: scenario)
        let stale = rig.router.snapshot()[0]
        if scenario == "cancel" { try await rig.control.cancel(stale) }
        if scenario == "reconnect" {
            rig.control.disconnected("pc", epoch: rig.epoch)
            #expect(throws: (any Error).self) { try rig.attest(stale) }
            let messages = rig.messages, fresh = UUID()
            try await rig.control.connected(rig.device, epoch: fresh) { await messages.send($0) }
            let request = try await messages.request()
            try rig.control.receive(AgentInventory(account_id: "fixture", device_id: "pc", request_id: request,
                authenticated_actor: "owner", sessions: [rig.wire]), from: "pc", epoch: fresh)
            #expect(throws: (any Error).self) { try rig.attest(stale) }
        }
        if scenario == "cancel" { #expect(throws: (any Error).self) { try rig.attest(stale) } }
        if scenario == "forged-success" {
            #expect(throws: (any Error).self) { try rig.control.receive(TaskStatus(account_id: "fixture", command_id: first.command.command_id,
                execution_state: .succeeded, updated_at: 1_000_000, outcome: .ok), from: "pc", epoch: rig.epoch) }
        }
        #expect(rig.router.snapshot()[0].state != .succeeded)
        #expect(rig.router.snapshot()[1].state == .queued)
    }
}

@Test @MainActor func phoneCompletionCardBindsTaskSessionOperationAndNextStepStillNeedsApproval() async throws {
    let agent = try AgentRig(); try await agent.install()
    let route = try #require(agent.control.destinations.first)
    try agent.control.choose(route.session)
    let tool = ToolCall.delegateTaskTool(DelegateTaskTool(account_id: "fixture", device_id: "pc", project_id: "arm",
        provider_session_id: "named-session", instruction: "Synthetic first"))
    let second = ToolCall.delegateTaskTool(DelegateTaskTool(account_id: "fixture", device_id: "pc", project_id: "arm",
        provider_session_id: "named-session", instruction: "Synthetic second"))
    let rig = try Rig(script: [.final("Research fixture. Then summarize fixture.")], additionalTool: second, tool: tool,
        agent: agent.control, policy: agent.gate)
    try await rig.registry.register(agent.device); await rig.model.refresh()
    try await rig.record(mode: .ai_control)
    let cards = rig.model.suggestions
    #expect(cards.count == 2)
    await rig.model.review(cards[0]); await rig.model.approve()
    let firstTask = try #require(agent.router.snapshot().first)
    try agent.delivered(firstTask.command)
    await rig.model.refreshTasks()
    await rig.model.review(cards[1]); #expect(rig.model.approval == nil)
    rig.model.reviewTaskCompletion(try #require(rig.model.tasks.first))
    #expect(rig.model.completion?.instruction == "Synthetic first")
    await rig.model.confirmTaskFinished()
    #expect(rig.model.tasks.first?.ownerConfirmed == true)
    #expect(agent.router.snapshot().count == 1)
    await rig.model.review(cards[1])
    #expect(rig.model.approval?.preview.risk == .sensitive)
    await rig.model.approve()
    #expect(agent.router.snapshot().count == 2)
    #expect(agent.router.snapshot()[1].state == .dispatched)
}

@MainActor private extension AgentRig {
    func installHost(_ id: String, provider: AgentSessionProvider) async throws -> (SessionIdentity, UUID) {
        let messages = AgentMessages(), epoch = UUID()
        let device = DeviceInfo(account_id: "fixture", device_id: id, display_name: "Synthetic " + id,
            platform: .linux, role: .agent, capabilities: [.delegate_task, .cancel_task, .open_resource])
        try await control.connected(device, epoch: epoch) { await messages.send($0) }
        let session = AgentSession(account_id: "fixture", device_id: id, project_id: "arm", workspace: "/synthetic/arm",
            provider: provider, provider_session_id: id + "-session", capability_profile: .read_only, capabilities: device.capabilities)
        try control.receive(AgentInventory(account_id: "fixture", device_id: id, request_id: try await messages.request(),
            authenticated_actor: "owner", sessions: [session]), from: id, epoch: epoch)
        return (try #require(control.destinations.first(where: { $0.id == id })?.session), epoch)
    }
}

@Test @MainActor func productionModelUsesExplicitSelectedRecentDefaultAndConfiguredFallbackRoutes() async throws {
    for scenario in ["explicit", "selected", "recent", "default", "local-fallback", "cloud-denied", "cloud-allowed", "machine-held", "named-offline", "unknown-name", "ordinary-prepositions"] {
        let agent = try AgentRig(); try await agent.install()
        let local = try #require(agent.control.destinations.first?.session)
        let (other, _) = try await agent.installHost("pc2", provider: .codex)
        let (cloud, _) = try await agent.installHost("cloud-host", provider: .cloud)
        var preferences = AgentRoutingSettings()
        preferences.project = "arm"; preferences.selectedSession = local; preferences.defaultSession = other
        preferences.independentCloudTasks = scenario != "machine-held"
        preferences.allowCloudFallback = scenario == "cloud-allowed" || scenario == "named-offline"
        if scenario == "recent" {
            preferences.selectedSession = nil; preferences.defaultSession = local
            preferences.independentCloudTasks = false
            preferences.recent = [AgentSessionUse(session: other, timestamp: 99)]
        }
        if scenario == "default" { preferences.selectedSession = nil }
        agent.control.configureRouting(preferences)
        var expected = local
        if ["explicit", "recent", "default"].contains(scenario) { expected = other }
        if scenario == "cloud-allowed" { expected = cloud }
        if scenario == "local-fallback" {
            let alternate = AgentSession(account_id: "fixture", device_id: "pc", project_id: "arm", workspace: agent.wire.workspace,
                provider: .claude, provider_session_id: "claude-local", capability_profile: .read_only, capabilities: agent.wire.capabilities)
            try agent.control.receive(await agent.inventory(session: alternate), from: "pc", epoch: agent.epoch)
            expected = try #require(agent.control.destinations.first(where: { $0.session.provider == "claude" })?.session)
        }
        if ["cloud-denied", "cloud-allowed", "machine-held", "named-offline"].contains(scenario) {
            agent.control.disconnected("pc", epoch: agent.epoch)
        }
        let text: String
        switch scenario {
        case "explicit": text = "Research on host pc2"
        case "named-offline": text = "Research on host pc"
        case "unknown-name": text = "Research on host missing"
        case "ordinary-prepositions": text = "Work on tests using fixtures"
        default: text = "Research the synthetic topic"
        }
        let rig = try Rig(script: [.final(text)], tool: .delegateTaskTool(DelegateTaskTool(account_id: "fixture", device_id: "pc",
            project_id: "arm", provider_session_id: "named-session", instruction: "Synthetic task")), agent: agent.control, policy: agent.gate)
        for id in ["pc", "pc2", "cloud-host"] {
            try await rig.registry.register(DeviceInfo(account_id: "fixture", device_id: id, display_name: "Synthetic " + id,
                platform: .linux, role: .agent, capabilities: [.delegate_task, .cancel_task, .open_resource]))
        }
        await rig.model.refresh(); try await rig.record(mode: .ai_control)
        await rig.model.review(try #require(rig.model.suggestions.first))
        if scenario == "unknown-name" {
            #expect(rig.model.approval == nil)
            #expect(agent.router.snapshot().isEmpty)
        } else if ["cloud-denied", "machine-held", "named-offline"].contains(scenario) {
            #expect(rig.model.approval?.route?.session == local)
            #expect(rig.model.approval?.route?.available == false)
            #expect(rig.model.approval?.routeDescription?.contains("will wait") == true)
            await rig.model.approve()
            #expect(agent.router.snapshot().first?.state == .queued)
            #expect(agent.router.snapshot().first?.hold != nil)
        } else {
            #expect(rig.model.approval?.route?.session == expected)
            #expect(rig.model.approval?.preview.risk == .sensitive)
            await rig.model.approve()
            #expect(agent.router.snapshot().count == 1)
            #expect(agent.router.snapshot().first?.route?.destination.session == expected)
            #expect(agent.router.snapshot().first?.state == .dispatched)
        }
    }
}

@Test @MainActor func routingPreferenceChangeRequiresNewApprovalAndPersistsFullIdentity() async throws {
    let agent = try AgentRig(); try await agent.install()
    let first = try #require(agent.control.destinations.first)
    let (other, _) = try await agent.installHost("pc2", provider: .claude)
    try agent.control.choose(first.session)
    var preferences = agent.control.routing; preferences.independentCloudTasks = true
    agent.control.configureRouting(preferences)
    let rig = try Rig(tool: .delegateTaskTool(DelegateTaskTool(account_id: "fixture", device_id: "pc", project_id: "arm",
        provider_session_id: "named-session", instruction: "Synthetic routing review")), agent: agent.control, policy: agent.gate)
    for id in ["pc", "pc2"] {
        try await rig.registry.register(DeviceInfo(account_id: "fixture", device_id: id, display_name: id, platform: .linux,
            role: .agent, capabilities: [.delegate_task, .cancel_task, .open_resource]))
    }
    await rig.model.refresh(); try await rig.record(mode: .ai_control)
    let suggestion = try #require(rig.model.suggestions.first)
    await rig.model.review(suggestion)
    #expect(rig.model.approval?.route?.session == first.session)
    try agent.control.choose(other)
    await rig.model.approve()
    #expect(agent.router.snapshot().isEmpty)
    // The changed destination appears in a fresh preview; it still needs another
    // owner approval and fresh LA before any dispatch.
    #expect(rig.model.approval?.route?.session == other)
    await rig.model.approve()
    #expect(agent.router.snapshot().count == 1)
    #expect(agent.router.snapshot().first?.route?.destination.session == other)
    #expect(agent.router.snapshot().first?.state == .dispatched)
    rig.model.settings.routing = agent.control.routing
    let encoded = try JSONEncoder().encode(rig.model.settings)
    let reopened = try JSONDecoder().decode(AppSettings.self, from: encoded)
    #expect(reopened.routing.selectedSession == other)
    #expect(reopened.routing.project == "arm")
    #expect(!reopened.routing.independentCloudTasks)
}

@Test @MainActor func heldIndependentTaskCanReviewCloudReplacementWithoutReusingOldApproval() async throws {
    let agent = try AgentRig(); try await agent.install()
    let local = try #require(agent.control.destinations.first)
    let (cloud, _) = try await agent.installHost("cloud-host", provider: .cloud)
    try agent.control.choose(local.session)
    var preferences = agent.control.routing
    preferences.independentCloudTasks = true; preferences.allowCloudFallback = true
    agent.control.configureRouting(preferences)
    let original = try await agent.permit(instruction: "Synthetic independent task")
    let rules = try agent.control.routingRules(project: "arm")
    _ = try agent.router.enqueue(original, rules: rules, destinations: agent.control.destinations)
    agent.control.disconnected("pc", epoch: agent.epoch)
    let held = try #require(agent.router.snapshot().first)
    #expect(held.state == .queued); #expect(held.hold == .reapprovalRequired)
    let rig = try Rig(agent: agent.control, policy: agent.gate)
    for id in ["pc", "cloud-host"] {
        try await rig.registry.register(DeviceInfo(account_id: "fixture", device_id: id, display_name: id, platform: .linux,
            role: .agent, capabilities: [.delegate_task, .cancel_task, .open_resource]))
    }
    await rig.model.refresh()
    rig.model.reviewRestoredTask(held)
    #expect(rig.model.approval?.route?.session == cloud)
    #expect(rig.model.approval?.preview.requestID.uuidString != original.command.candidate_id)
    #expect(agent.router.snapshot().count == 1)
    await rig.model.approve()
    #expect(agent.router.snapshot().count == 2)
    #expect(agent.router.snapshot()[0].state == .cancelled)
    #expect(agent.router.snapshot()[1].route?.destination.session == cloud)
    #expect(agent.router.snapshot()[1].state == .dispatched)
}

@Test @MainActor func changedSelectionCannotMoveMachineBoundReviewToAnUnrelatedHost() async throws {
    let agent = try AgentRig(); try await agent.install()
    let local = try #require(agent.control.destinations.first)
    let (other, _) = try await agent.installHost("pc2", provider: .codex)
    try agent.control.choose(local.session)
    let rig = try Rig(tool: .delegateTaskTool(DelegateTaskTool(account_id: "fixture", device_id: "pc", project_id: "arm",
        provider_session_id: "named-session", instruction: "Inspect the synthetic local file")), agent: agent.control, policy: agent.gate)
    for id in ["pc", "pc2"] {
        try await rig.registry.register(DeviceInfo(account_id: "fixture", device_id: id, display_name: id, platform: .linux,
            role: .agent, capabilities: [.delegate_task, .cancel_task, .open_resource]))
    }
    await rig.model.refresh(); try await rig.record(mode: .ai_control)
    await rig.model.review(try #require(rig.model.suggestions.first))
    try agent.control.choose(other)
    await rig.model.approve()
    #expect(agent.router.snapshot().isEmpty)
    #expect(rig.model.approval?.route?.session != other)
    if let card = rig.model.suggestions.first { await rig.model.review(card) }
    #expect(rig.model.approval?.route?.session != other)
    #expect(agent.router.snapshot().isEmpty)
}
