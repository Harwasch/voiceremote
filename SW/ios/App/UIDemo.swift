#if DEBUG
// Purpose: deterministic synthetic UI fixtures. Inputs: launch arguments only.
// Verification: portable adapter typecheck; Apple UI execution remains unverified.
import Foundation
import AppModel
import Core
import Stt
import Brain
import Policy
import Router
import VoiceRemoteProtocol

@MainActor final class UIDemo {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--ui-demo") }
    let arguments = ProcessInfo.processInfo.arguments
    var firstRun: Bool { arguments.contains("--ui-first-run") }
    var denied: Bool { arguments.contains("--ui-permission-denied") }
    let target = DemoTarget()
    let biometric: DemoBiometric
    let messages = DemoAgentTransport()
    weak var model: VoiceAppModel?
    var destinationBeforeCapture = false
    var prepared = false
    var seeding = false
    let epoch = UUID()
    static let account = "ui-synthetic"
    static let phone = "synthetic-phone"
    static let computer = DeviceInfo(account_id: account, device_id: "synthetic-pc", display_name: "Synthetic Studio",
        platform: .windows, role: .both, capabilities: [.receive_text, .delegate_task, .cancel_task, .open_resource])
    static let offline = DeviceInfo(account_id: account, device_id: "synthetic-laptop", display_name: "Synthetic Laptop",
        platform: .linux, role: .both, capabilities: [.receive_text, .delegate_task, .cancel_task])
    init() { biometric = DemoBiometric(refuse: ProcessInfo.processInfo.arguments.contains("--ui-biometric-refuse")) }
    func makeCapture() async throws -> any CaptureSession {
        destinationBeforeCapture = model?.destination != nil && model?.partial.isEmpty == true
        if !seeding && arguments.contains("--ui-slow-prepare") { try await Task.sleep(for: .seconds(120)) }
        let capture = DemoCapture(fail: !seeding && arguments.contains("--ui-capture-failure"))
        if !seeding && arguments.contains("--ui-interrupt") { capture.interruptAfterStart = true }
        return capture
    }
    var engines: [any SttEngine] {
        [DemoSpeech(id: "apple", slow: !seeding && arguments.contains("--ui-slow-finish")), DemoSpeech(id: "whisperkit", slow: false)]
    }
    func seed(_ host: VoiceAppModel, history: AppHistoryStore, registry: DeviceRegistry, agents: AgentControl) async throws {
        guard !prepared else { return }; prepared = true
        seeding = true; defer { seeding = false }
        model = host
        host.settings.speechEngine = "apple"
        host.settings.comparisonEngine = "whisperkit"
        host.settings.compare = true
        if firstRun || denied { await host.refresh(); return }
        for device in [Self.computer, Self.offline] {
            try await registry.register(device)
            let transport = messages
            let connection = device == Self.computer ? epoch : UUID()
            try await agents.connected(device, epoch: connection) { try await transport.send($0) }
            let wire = AgentSession(account_id: Self.account, device_id: device.device_id, project_id: "synthetic-project",
                workspace: "/synthetic/workspace", provider: .codex, provider_session_id: device.device_id + "-session",
                capability_profile: .read_only, capabilities: [.delegate_task, .cancel_task])
            let request = try await messages.inventoryRequest()
            try agents.receive(AgentInventory(account_id: Self.account, device_id: device.device_id,
                request_id: request, authenticated_actor: Self.phone, sessions: [wire]), from: device.device_id, epoch: connection)
            if device == Self.offline { agents.disconnected(device.device_id, epoch: connection) }
        }
        let epoch = self.epoch
        await messages.configure { dispatch in
            try await MainActor.run {
                try agents.receive(TaskStatus(account_id: "ui-synthetic", command_id: dispatch.command.command_id,
                    execution_state: .dispatched, updated_at: Int64(Date().timeIntervalSince1970 * 1000), outcome: .dispatched),
                    from: "synthetic-pc", epoch: epoch)
            }
        }
        guard let session = agents.destinations.first(where: { $0.id == Self.computer.device_id })?.session else { throw RouterError.invalidStatus }
        try agents.choose(session)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await history.saveText(HistoryEntry(segmentID: "synthetic-held", targetID: Self.computer.device_id,
            text: "Synthetic held note for review.", createdAt: now, accountID: Self.account), state: .held, now: now)
        try await history.saveText(HistoryEntry(segmentID: "synthetic-unconfirmed", targetID: Self.computer.device_id,
            text: "Synthetic unconfirmed note. Check the computer first.", createdAt: now, accountID: Self.account), state: .unconfirmed, now: now)
        await host.refresh()
        host.setTarget(.auto)
        host.grantTargetSelection(device: Self.computer, project: "synthetic-project")
        // Generate a card through capture → STT → Brain → SuggestionEngine.
        // Seeding never assigns approval or queue state; Policy binds trusted phone events.
        host.setMode(.ai_control); host.setCapture(.continuous)
        for _ in 0..<500 where !host.isRecording { try await Task.sleep(for: .milliseconds(10)) }
        guard host.isRecording else { throw SttFailure.unavailable }
        host.finishUtterance()
        for _ in 0..<500 where host.listening != .idle { try await Task.sleep(for: .milliseconds(10)) }
        guard host.listening == .idle, host.suggestions.count == 1, host.grants.count == 1 else { throw SttFailure.invalidResponse }
        host.stop(); host.setMode(.dictation); host.setCapture(.hold)
        // A later UI assertion must prove its own capture, never the seed run.
        destinationBeforeCapture = false
    }
}

@MainActor final class DemoCapture: CaptureSession {
    nonisolated let channel = AsyncStream<CaptureEvent>.makeStream()
    let fail: Bool
    var interruptAfterStart = false
    init(fail: Bool = false) { self.fail = fail }
    nonisolated func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    nonisolated func events() -> AsyncStream<CaptureEvent> { channel.stream }
    func start() throws {
        if fail { throw SttFailure.unavailable }
        channel.continuation.yield(.frame(try AudioFrame(samples: [800, -800, 800], timestamp: 0)))
        if interruptAfterStart { interrupt() }
    }
    func finish() { channel.continuation.finish() }
    func interrupt() { channel.continuation.yield(.interrupted); channel.continuation.finish() }
}
struct DemoSpeech: SttEngine {
    let id: String
    let slow: Bool
    var descriptor: EngineDescriptor { .init(id: id, version: "synthetic-ui", location: .onDevice) }
    func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
        AsyncStream { output in
            let worker = Task {
                output.yield(.partial("Synthetic words for review"))
                for await _ in audio { if Task.isCancelled { break } }
                if slow { try? await Task.sleep(for: .seconds(120)) }
                if !Task.isCancelled { output.yield(.final("Please draft a synthetic workspace note")) }
                output.finish()
            }
            output.onTermination = { _ in worker.cancel() }
        }
    }
}
struct DemoBrain: LlmBrain {
    func propose(_ request: BrainRequest) async throws -> BrainResponse {
        let tool = ToolCall.delegateTaskTool(DelegateTaskTool(account_id: "ui-synthetic", device_id: "synthetic-pc",
            project_id: "synthetic-project", provider_session_id: "synthetic-pc-session", instruction: "Draft a synthetic workspace note."))
        let bytes = try JSONSerialization.data(withJSONObject: [JSONSerialization.jsonObject(with: ProtocolCodec.encode(tool))])
        return ProposalDecoder.decode(bytes, accountID: "ui-synthetic")
    }
}
actor DemoTarget: DictationAvailability, DeviceRevocationHandler {
    func showTarget(_ device: DeviceInfo) {}
    func isReachable(_ deviceID: String) -> Bool { deviceID != "synthetic-laptop" }
    func insert(_ text: DictationText) throws { throw DictationDeliveryError.unconfirmed }
    func deleteKey(deviceID: String) {}
    func dropRoom(deviceID: String) {}
}
@MainActor final class DemoPairing: ComputerPairing {
    let registry: DeviceRegistry
    var pending: DeviceInfo?
    init(registry: DeviceRegistry) { self.registry = registry }
    func begin(_ invitationOrCode: String, role: DeviceInfoRole) throws -> String {
        guard invitationOrCode == "voiceremote://synthetic-invitation" else { throw CoreError.unavailableTarget }
        pending = DeviceInfo(account_id: UIDemo.account, device_id: "synthetic-new", display_name: "Synthetic New Computer",
            platform: .linux, role: role, capabilities: [.receive_text])
        return "maple river copper orbit"
    }
    func confirm(_ phrase: String) async throws -> DeviceInfo {
        guard phrase == "maple river copper orbit", let device = pending else { throw CoreError.unavailableTarget }
        try await registry.register(device); pending = nil; return device
    }
    func cancel() { pending = nil }
}
@MainActor final class DemoBiometric: Biometric {
    let refuse: Bool
    init(refuse: Bool) { self.refuse = refuse }
    func authenticate(_ challenge: AuthenticationChallenge) async throws -> AuthenticationResult {
        if refuse { throw PolicyError.invalid }
        return AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
@MainActor final class DemoJournal: AuditJournal {
    var data = Data()
    func read() -> Data { data }
    func append(_ bytes: Data) { data.append(bytes) }
}
@MainActor final class DemoCheckpoint: AuditCheckpointStore {
    var value = AuditCheckpoint.empty
    var pending: AuditPending?
    func load() -> AuditCheckpoint { value }
    func save(_ value: AuditCheckpoint) { self.value = value }
    func loadPending() -> AuditPending? { pending }
    func savePending(_ value: AuditPending?) { pending = value }
}
actor DemoAgentTransport {
    var request: String?
    private var delivery: (@Sendable (AgentDispatch) async throws -> Void)?
    func configure(_ delivery: @escaping @Sendable (AgentDispatch) async throws -> Void) { self.delivery = delivery }
    func send(_ value: InnerMessage) async throws {
        if case .agentInventoryRequest(let inventory) = value { request = inventory.request_id }
        if case .agentDispatch(let dispatch) = value { try await delivery?(dispatch) }
        // Synthetic delivery acknowledgement only; effects require owner confirmation.
    }
    func inventoryRequest() throws -> String {
        guard let request else { throw RouterError.invalidStatus }; return request
    }
}
#endif
