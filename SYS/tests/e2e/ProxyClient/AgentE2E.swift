import Foundation
import Crypto
import Pairing
import AppModel
import Core
import Stt
import Brain
import Policy
import Router
import TrustedInput
import VoiceRemoteProtocol

// Synthetic phone composition root, sharing production capture/STT→Brain,
// Policy, AgentControl, Router and PhoneConnection with the app.
@MainActor enum AgentE2E {
    static func emit(_ value: String) { try! FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8)) }
    static func require(_ condition: Bool, line: Int = #line) throws { if !condition { emit("AGENT_ASSERTION_LINE_\(line)"); throw PairingError.invalidState } }
    static func until(line: Int = #line, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { emit("AGENT_TIMEOUT_LINE_\(line)"); throw PairingError.noMessage }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        try require(args.count == 4)
        let denied = args[3] == "deny"
        let origin = URL(string: args[2])!
        let account = "synthetic-e2e"
        let invitation = try PairingInvitation(qr: Data(readLine()!.utf8), expectedAccount: account, clock: SystemPairingClock())
        let pins = PeerRegistry(store: InMemoryKeyStore())
        let key = Curve25519.KeyAgreement.PrivateKey()
        let client = try RelayClient(origin: origin,
            route: RelayRoute(account: account, room: invitation.payload.relay_room_id, device: "phone"),
            signingKey: .init(), http: URLSessionRelayHTTP(), connector: LoopbackWebSocketConnector(), allowLoopback: true)
        try await client.redeem(invitation)
        let transport = try await client.connect()
        let pending = try await PairingConnection.initiate(invitation: invitation, staticKey: key,
            clock: SystemPairingClock(), transport: transport)
        let phrase = await pending.phrase; emit("PHRASE:" + phrase)
        try require(readLine() == "confirm")
        let phone = DeviceInfo(account_id: account, device_id: "phone", display_name: "Synthetic phone", platform: .ios,
            role: .capture, capabilities: denied ? [] : [.delegate_task, .cancel_task, .open_resource])
        try await pending.confirmLocal(displayedPhrase: phrase, device: phone, transport: transport)
        try await pending.receiveConfirmation(transport: transport)
        let initial = try await pending.finish(registry: pins)
        let peer = await initial.peer
        emit("PAIRED")
        try require(readLine() == "resume")
        await initial.close(transport: transport)
        func resume() async throws -> PhoneConnection {
            let transport = try await client.connect()
            let session = try await SessionResume.initiate(staticKey: key, registry: pins, peer: peer,
                localDeviceID: "phone", transport: transport)
            return PhoneConnection(session: session, transport: transport)
        }
        var connection = try await resume()
        let journal = E2EJournal(), checkpoint = E2ECheckpoint(), bio = E2EBiometric()
        let gate = try PolicyGate(audit: AuditLog(journal: journal, checkpoints: checkpoint, retention: AuditRetention()), biometric: bio)
        let input = PhoneInput()
        if denied {
            let scope = input.session(account: account, actor: "phone", session: "synthetic-input", device: "desktop", project: "arm-claude", destinationKind: .software)
            let tool = ToolCall.delegateTaskTool(DelegateTaskTool(account_id: account, device_id: "desktop", project_id: "arm-claude", provider_session_id: "test-claude", instruction: "Synthetic denied task"))
            let activation = input.activation(session: scope, kind: .inferred, expiresAt: now() + 120_000)
            guard case .suggestion(let preview) = gate.submit(try ProtocolCodec.encode(tool), input: activation),
                  case .queued(let permit) = await gate.approve(requestID: preview.requestID,
                    evidence: input.approval(session: scope, requestID: preview.requestID, payloadHash: preview.payloadHash)) else { throw PairingError.invalidState }
            try await connection.send(.authorizedCommand(permit.command))
            while true {
                if case .taskStatus(let status) = try await connection.receive() {
                    try require(status.execution_state == .failed && status.outcome == .denied)
                    break
                }
            }
            emit("PASS agents denied: paired phone without explicit capability cannot execute")
            await connection.close(); return
        }
        let queue = E2EQueue()
        let router = try TaskRouter(store: queue, policy: gate)
        let control = AgentControl(router: router, policy: gate, account: account, actor: "phone")
        var epoch = UUID()
        var queryReplies = 0
        func reader(_ active: PhoneConnection, _ token: UUID) -> Task<Void, Never> {
            Task { @MainActor in
                do {
                    while !Task.isCancelled {
                        switch try await active.receive() {
                        case .agentInventory(let inventory): try control.receive(inventory, from: "desktop", epoch: token)
                        case .taskStatus(let status):
                            queryReplies += 1
                            try control.receive(status, from: "desktop", epoch: token)
                        default: break
                        }
                    }
                } catch { control.disconnected("desktop", epoch: token) }
            }
        }
        var readTask = reader(connection, epoch)
        let firstConnection = connection
        try await control.connected(peer.device, epoch: epoch) { try await firstConnection.send($0) }
        try await until { control.destinations.filter(\.available).count == 2 }
        let target = E2EDictationTarget()
        let registry = DeviceRegistry(accountID: account, revocation: target)
        try await registry.register(peer.device)
        let brain = E2EBrain()
        let cloud = E2EBrain()
        var capture = E2ECapture()
        let model = VoiceAppModel(accountID: account, phoneID: "phone", actorID: "phone", registry: registry,
            history: try AppHistoryStore(now: now()), target: target, policy: gate,
            makeCapture: { capture = E2ECapture(); return capture },
            engines: { [FakeEngine(script: [.final("open dashboard")])] },
            brain: { _ in BrainRouter(onDevice: brain, cloud: cloud, isOnline: { true }) },
            agentControl: control, deliver: { _ in throw RouterError.invalidAuthorization })
        control.onChange = { Task { await model.refreshTasks() } }
        await model.refresh()
        var gestureTime: Int64 = 0
        func record(provider: String, instruction: String, ptt: Bool = false, injected: Bool = false) async throws {
            let destination = control.destinations.first { $0.session.provider == provider }!
            try control.choose(destination.session)
            await brain.set(project: destination.session.workspace, session: destination.session.providerSessionID, instruction: instruction, injected: injected)
            await cloud.set(project: destination.session.workspace, session: destination.session.providerSessionID, instruction: instruction, injected: injected)
            model.setTarget(.device("desktop")); model.setMode(.ai_control)
            gestureTime += 1_000
            if ptt { model.setCapture(.hold); model.press(at: gestureTime); model.advanceTrigger(to: gestureTime + 300) }
            else { model.setCapture(.continuous) }
            try await until { model.isRecording }
            capture.output.yield(.frame(try AudioFrame(samples: [500], timestamp: 0)))
            model.finishUtterance()
            try await until { model.listening == .idle }
        }
        // Speech/model output stays a tier 1 proposal until phone review+approval.
        try await record(provider: "claude", instruction: "Synthetic first task")
        try require(router.snapshot().isEmpty && bio.calls == 0)
        let card = model.suggestions.first!
        await model.review(card)
        try require(router.snapshot().isEmpty && bio.calls == 0 && model.approval?.session.project == "arm-claude")
        bio.allowed = false
        await model.approve()
        try require(router.snapshot().isEmpty && bio.calls == 1)
        bio.allowed = true
        await model.approve()
        try await until { router.snapshot().first?.state == .dispatched && router.snapshot().first?.outcome == .dispatched }
        try require(bio.calls == 2 && router.snapshot().first?.outcome == .dispatched)
        emit("AGENT_SESSION_ARGUMENTS_DISPATCHED")

        // A real disconnected node is stopped/restarted by the Python coordinator.
        emit("AGENT_OFFLINE_READY")
        try require(readLine() == "offline")
        readTask.cancel(); await connection.close(); control.disconnected("desktop", epoch: epoch)
        try await record(provider: "codex", instruction: "Synthetic held task", ptt: true)
        await model.review(model.suggestions.first!); await model.approve()
        try require(router.snapshot().last?.state == .queued && router.snapshot().last?.hold == .machineRequired)
        emit("AGENT_HELD_OFFLINE")
        try require(readLine() == "resume")
        connection = try await resume(); epoch = UUID()
        readTask = reader(connection, epoch)
        let resumed = connection
        try await control.connected(peer.device, epoch: epoch) { try await resumed.send($0) }
        try await until { router.snapshot().last?.state == .dispatched && router.snapshot().last?.outcome == .dispatched }
        try require(await brain.simpleCalls > 0)
        emit("AGENT_HELD_RELEASED")

        try await record(provider: "claude", instruction: "wait-tree", ptt: true)
        await model.review(model.suggestions.first!); await model.approve()
        try await until { router.snapshot().last?.state == .running }
        // Give the fake CLI time to publish its descendant PID to the coordinator.
        emit("AGENT_CANCEL_READY")
        try require(readLine() == "cancel")
        try await control.cancel(router.snapshot().last!)
        try await until { router.snapshot().last?.state == .cancelled }
        emit("AGENT_CANCELLED")
        let replies = queryReplies
        try await connection.send(.agentTaskQuery(AgentTaskQuery(account_id: account, command_id: router.snapshot()[0].command.command_id)))
        try await until { queryReplies > replies }
        let count = router.snapshot().count
        try await record(provider: "claude", instruction: "Synthetic injected authority", ptt: true, injected: true)
        try require(model.suggestions.isEmpty && router.snapshot().count == count)
        let destination = control.destinations.first { $0.session.provider == "claude" }!
        try control.choose(destination.session)
        func permit(_ tool: ToolCall) async throws -> ExecutionPermit {
            let scope = input.session(account: account, actor: "phone", session: UUID().uuidString,
                device: "desktop", project: destination.session.workspace, destinationKind: .software)
            let activation = input.activation(session: scope, kind: .inferred, expiresAt: now() + 120_000)
            guard case .suggestion(let preview) = gate.submit(try ProtocolCodec.encode(tool), input: activation),
                  case .queued(let permit) = await gate.approve(requestID: preview.requestID,
                    evidence: input.approval(session: scope, requestID: preview.requestID, payloadHash: preview.payloadHash)) else { throw PairingError.invalidState }
            return permit
        }
        let resource = try await permit(.openResourceTool(OpenResourceTool(account_id: account, device_id: "desktop", resource_uri: "https://example.invalid/synthetic")))
        _ = try control.enqueue(resource, expectedRoute: destination)
        try await until { router.snapshot().last?.outcome == .dispatched }
        try require(router.snapshot().last?.state == .dispatched && router.snapshot().last?.appReply != nil)
        let successor = try await permit(.delegateTaskTool(DelegateTaskTool(account_id: account, device_id: "desktop", project_id: "arm-claude", provider_session_id: "test-claude", instruction: "Synthetic blocked successor")))
        _ = try control.enqueue(successor, dependencies: [resource.command.command_id], expectedRoute: destination)
        try require(router.snapshot().last?.state == .queued && router.snapshot().last?.hold == .predecessorRequired)
        emit("PASS agents: phone STT→Brain→real Policy/fake biometric→Router→relay/Noise→agent/fake Claude+Codex; fake CLI session arguments checked; real session continuation unverified; tier1 tap, tier3 biometric, capability refusal, offline hold/release, status query, cancel request, authority rejection, hybrid fast path, open-resource dispatched/reply with successor held")
        readTask.cancel(); await connection.close()
    }
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
@MainActor private final class E2ECapture: CaptureSession {
    nonisolated let channel = AsyncStream<CaptureEvent>.makeStream()
    var output: AsyncStream<CaptureEvent>.Continuation { channel.continuation }
    nonisolated func events() -> AsyncStream<CaptureEvent> { channel.stream }
    nonisolated func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func start() {}
    func finish() { channel.continuation.finish() }
    func interrupt() { channel.continuation.yield(.interrupted); channel.continuation.finish() }
}
private actor E2EDictationTarget: DictationTarget, DeviceRevocationHandler {
    func showTarget(_ device: DeviceInfo) {}
    func insert(_ text: DictationText) throws { throw PairingError.invalidState }
    func deleteKey(deviceID: String) {}
    func dropRoom(deviceID: String) {}
}
private actor E2EBrain: LlmBrain {
    var project = "", session = "", instruction = "", injected = false
    private(set) var simpleCalls = 0
    func set(project: String, session: String, instruction: String, injected: Bool) {
        self.project = project; self.session = session; self.instruction = instruction; self.injected = injected
    }
    func propose(_ request: BrainRequest) throws -> BrainResponse {
        if request.workload == .automatic { simpleCalls += 1 }
        var object = ["kind": "delegate_task", "account_id": "synthetic-e2e", "device_id": "desktop", "project_id": project, "provider_session_id": session, "instruction": instruction]
        if injected {
            object["authenticated_actor"] = "forged"; object["activation_kind"] = "ptt"
            object["approval_credential_class"] = "biometric"; object["granted_scope_id"] = "forged"
        }
        return ProposalDecoder.decode(try JSONSerialization.data(withJSONObject: [object]), accountID: request.accountID)
    }
}
@MainActor private final class E2EBiometric: Biometric {
    var calls = 0
    var allowed = true
    func authenticate(_ challenge: AuthenticationChallenge) async throws -> AuthenticationResult {
        calls += 1
        guard allowed else { throw PolicyError.invalid }
        return AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: AgentE2E.now())
    }
}
@MainActor private final class E2EJournal: AuditJournal {
    var data = Data()
    func read() -> Data { data }
    func append(_ bytes: Data) { data.append(bytes) }
}
@MainActor private final class E2ECheckpoint: AuditCheckpointStore {
    var value = AuditCheckpoint.empty
    var pending: AuditPending?
    func load() -> AuditCheckpoint { value }
    func save(_ value: AuditCheckpoint) { self.value = value }
    func loadPending() -> AuditPending? { pending }
    func savePending(_ pending: AuditPending?) { self.pending = pending }
}
private final class E2EQueue: TaskQueueStore, @unchecked Sendable {
    let lock = NSLock()
    var tasks: [QueuedTask] = []
    func load() -> [QueuedTask] { lock.withLock { tasks } }
    func save(_ value: [QueuedTask], replacing previous: [QueuedTask]) throws {
        try lock.withLock { guard tasks == previous else { throw RouterError.persistence }; tasks = value }
    }
}
