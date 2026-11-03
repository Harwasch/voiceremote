import Foundation
import Testing
import Core
import Stt
import Brain
import Policy
import Router
import TrustedInput
import VoiceRemoteProtocol
@testable import AppModel

@MainActor final class Capture: CaptureSession {
    nonisolated let channel = AsyncStream<CaptureEvent>.makeStream()
    var starts = 0
    var stopped = false
    var failStart = false
    var onStart: (() -> Void)?
    nonisolated func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    nonisolated func events() -> AsyncStream<CaptureEvent> { channel.stream }
    func start() throws { if failStart { throw SttFailure.unavailable }; starts += 1; onStart?() }
    func finish() { stopped = true; channel.continuation.finish() }
    func interrupt() { stopped = true; channel.continuation.yield(.interrupted); channel.continuation.finish() }
}
actor TargetSpy: DictationTarget, DeviceRevocationHandler {
    var presented: [String] = []
    var inserted: [DictationText] = []
    func showTarget(_ device: DeviceInfo) { presented.append(device.device_id) }
    func insert(_ text: DictationText) { inserted.append(text) }
    func deleteKey(deviceID: String) {}
    func dropRoom(deviceID: String) {}
}
actor BrainSpy: LlmBrain {
    var calls = 0
    let sensitive: Bool
    let fixtureTool: ToolCall?
    init(sensitive: Bool = false, tool: ToolCall? = nil) { self.sensitive = sensitive; fixtureTool = tool }
    func propose(_ request: BrainRequest) throws -> BrainResponse {
        calls += 1
        let tool: ToolCall = fixtureTool ?? (sensitive
            ? .prepareSendTool(PrepareSendTool(account_id: "fixture", device_id: "phone", recipient: "fixture-recipient", content: "invented content"))
            : .selectTargetTool(SelectTargetTool(account_id: "fixture", device_id: "phone")))
        return ProposalDecoder.decode(try JSONSerialization.data(withJSONObject: [JSONSerialization.jsonObject(with: ProtocolCodec.encode(tool))]), accountID: "fixture")
    }
}
@MainActor final class Journal: AuditJournal {
    var data = Data()
    func read() -> Data { data }
    func append(_ bytes: Data) { data.append(bytes) }
}
@MainActor final class Checkpoint: AuditCheckpointStore {
    var value = AuditCheckpoint.empty
    var pending: AuditPending?
    func load() -> AuditCheckpoint { value }
    func save(_ value: AuditCheckpoint) { self.value = value }
    func loadPending() -> AuditPending? { pending }
    func savePending(_ pending: AuditPending?) { self.pending = pending }
}
@MainActor final class Bio: Biometric {
    var count = 0
    var allowed = true
    func authenticate(_ challenge: AuthenticationChallenge) async throws -> AuthenticationResult {
        count += 1
        guard allowed else { throw PolicyError.invalid }
        return AuthenticationResult(challenge: challenge, credential: .biometric, authenticatedAt: 1_000_000)
    }
}
@MainActor final class ExecutionSpy { var permits: [ExecutionPermit] = [] }
@MainActor final class Rig {
    let capture = Capture()
    let target = TargetSpy()
    let brain: BrainSpy
    let bio = Bio()
    let gate: PolicyGate
    let model: VoiceAppModel
    let history: AppHistoryStore
    let registry: DeviceRegistry
    let execution = ExecutionSpy()
    init(sensitive: Bool = false, script: [SttEvent] = [.final("invented words")],
         captureFactory: (@MainActor () async throws -> any CaptureSession)? = nil,
         tool: ToolCall? = nil,
         delivery: (@MainActor (ExecutionPermit) throws -> [QueuedTask])? = nil) throws {
        brain = BrainSpy(sensitive: sensitive, tool: tool)
        gate = try PolicyGate(audit: AuditLog(journal: Journal(), checkpoints: Checkpoint(), retention: AuditRetention()), biometric: bio, clock: { 1_000_000 })
        history = try AppHistoryStore(now: 1_000_000)
        registry = DeviceRegistry(accountID: "fixture", revocation: target)
        let capture = self.capture, brain = self.brain, execution = self.execution
        model = VoiceAppModel(accountID: "fixture", phoneID: "phone", actorID: "owner", registry: registry,
            history: history, target: target, policy: gate, makeCapture: captureFactory ?? { capture },
            engines: { [FakeEngine(script: script)] }, brain: { _ in brain }, now: { 1_000_000 }, deliver: delivery ?? { permit in execution.permits.append(permit); return [] })
    }
    func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for app state: \(model.listening)")
    }
    func record(mode: Mode = .dictation) async throws {
        model.setMode(mode); model.setCapture(.continuous)
        try await until { model.isRecording }
        capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500, 200], timestamp: 0)))
        model.finishUtterance()
        try await until { model.listening == .idle }
    }
}

@Test @MainActor func dictationNeverCallsBrainAndDestinationPrecedesAudio() async throws {
    let rig = try Rig()
    rig.capture.onStart = { #expect(rig.model.destination?.device_id == "phone") }
    try await rig.record()
    #expect(await rig.brain.calls == 0)
    #expect(await rig.target.presented == ["phone"])
    #expect(await rig.target.inserted.count == 1)
    #expect(rig.model.history.first?.text == "Invented words.")
}
@Test @MainActor func modeKeepsTargetAndStopClearsEveryCaptureState() async throws {
    let rig = try Rig()
    rig.model.setTarget(.device("phone"))
    rig.model.setMode(.ai_control)
    #expect(rig.model.controls.target == .device("phone"))
    for state in [CaptureState.off, .hold, .continuous] {
        rig.model.setCapture(state); rig.model.stop()
        #expect(rig.model.controls.capture == .off)
        #expect(rig.model.listening == .idle)
        #expect(rig.model.controls.target == .device("phone"))
    }
    rig.model.interrupt(); rig.model.stop(); #expect(rig.model.listening == .idle)
}
@Test @MainActor func stopDuringListeningAndFinishingDropsLateText() async throws {
    for finishing in [false, true] {
        let rig = try Rig()
        rig.model.setCapture(.continuous); try await rig.until { rig.model.isRecording }
        if finishing { rig.model.finishUtterance() }
        rig.model.stop()
        try await Task.sleep(for: .milliseconds(10))
        #expect(rig.capture.stopped)
        #expect(await rig.target.inserted.isEmpty)
        #expect(await rig.brain.calls == 0)
    }
}
@Test @MainActor func suggestionCannotExecuteUntilPhoneTapAndSensitivePolicyAuthentication() async throws {
    let rig = try Rig(sensitive: true)
    try await rig.record(mode: .ai_control)
    #expect(rig.model.approval == nil)
    #expect(rig.bio.count == 0)
    #expect(rig.execution.permits.isEmpty)
    let card = try #require(rig.model.suggestions.first)
    await rig.model.review(card)
    #expect(rig.model.approval?.preview.risk == .sensitive)
    #expect(rig.bio.count == 0)
    await rig.model.approve(source: .remoteButton)
    #expect(rig.bio.count == 0)
    #expect(rig.model.approval != nil)
    #expect(rig.execution.permits.isEmpty)
    await rig.model.approve()
    #expect(rig.bio.count == 1)
    #expect(rig.model.approval == nil)
    #expect(rig.execution.permits.count == 1)
    #expect(rig.execution.permits.first?.command.approval_credential_class == .biometric)
    #expect(rig.execution.permits.first?.command.activation_kind == .approval_tap)
}
@Test @MainActor func deniedBiometricNeverApproves() async throws {
    let rig = try Rig(sensitive: true); rig.bio.allowed = false
    try await rig.record(mode: .ai_control)
    await rig.model.review(try #require(rig.model.suggestions.first))
    let id = try #require(rig.model.approval?.id)
    await rig.model.approve()
    #expect(rig.gate.state(requestID: id) != .queued)
    #expect(rig.execution.permits.isEmpty)
}
@Test @MainActor func interruptedCaptureDiscardsAllUncommittedDictationAndCommands() async throws {
    for mode in [Mode.dictation, .ai_control] {
        let rig = try Rig()
        rig.model.setMode(mode); rig.model.setCapture(.continuous)
        try await rig.until { rig.model.isRecording }; rig.capture.interrupt()
        try await rig.until { rig.model.listening == .interrupted }
        #expect(await rig.target.inserted.isEmpty)
        #expect(await rig.brain.calls == 0)
        #expect(rig.model.history.isEmpty)
    }
}
@Test @MainActor func historyExpiresAndDeletes() async throws {
    let store = try AppHistoryStore(now: 1)
    try await store.append(.init(segmentID: "fixture", targetID: "phone", text: "invented", createdAt: 1), now: 1)
    #expect(try await store.entries(now: 604_800_001).isEmpty)
    try await store.append(.init(segmentID: "fixture", targetID: "phone", text: "invented", createdAt: 2), now: 2)
    try await store.delete(id: "fixture", now: 2)
    #expect(try await store.entries(now: 2).isEmpty)
}
@Test @MainActor func recorderExportMatchesAuthoritativeSchemaAndDeletesAudioOnlyAfterSuccess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try BenchmarkRecorder(prompts: [.init(id: "fixture-1", category: "normal", expectedText: "invented words")], directory: directory)
    let source = Capture()
    recorder.start(source: source, first: FakeEngine(id: "one", script: [.final("invented words")]),
        second: FakeEngine(id: "two", script: [.final("invented words")]), vocabulary: Vocabulary(userID: "fixture", terms: []),
        device: "Linux synthetic", captureKind: .synthetic, cloudConsent: false, synthetic: true)
    for _ in 0..<2000 { if source.starts > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
    source.channel.continuation.yield(.frame(try AudioFrame(samples: [0, 1, 2], timestamp: 0)))
    recorder.finish()
    for _ in 0..<2000 { if recorder.completed == 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
    #expect(recorder.completed == 1)
    let json = try Data(contentsOf: recorder.prepareExport())
    try BenchSchemaValidator.repositorySchema().validate(json)
    func audioCount() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".pcm") }.count }
    #expect(try audioCount() == 1)
    try recorder.exportCompleted(success: false); #expect(try audioCount() == 1)
    try recorder.exportCompleted(success: true); #expect(try audioCount() == 0)
}

@Test @MainActor func stopClearsFailedStateAndModeKeepsCaptureSelection() async throws {
    let rig = try Rig(); rig.capture.failStart = true
    rig.model.setCapture(.hold); rig.model.setMode(.ai_control)
    #expect(rig.model.controls.capture == .hold)
    rig.model.setCapture(.continuous)
    try await rig.until { rig.model.listening == .failed }
    rig.model.stop()
    #expect(rig.model.listening == .idle)
    #expect(rig.model.partial.isEmpty)
    #expect(await rig.target.inserted.isEmpty)
}
@Test @MainActor func mutedSuggestionCannotOpenApproval() async throws {
    let rig = try Rig(); try await rig.record(mode: .ai_control)
    let card = try #require(rig.model.suggestions.first)
    await rig.model.muteSuggestions(true)
    #expect(rig.model.suggestions.isEmpty)
    await rig.model.review(card)
    #expect(rig.model.approval == nil)
}

@Test @MainActor func recorderKeepAudioSurvivesNextLaunchAndAbandonedAudioDoesNot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prompts = [RecorderPrompt(id: "fixture", category: "normal", expectedText: "invented")]
    let recorder = try BenchmarkRecorder(prompts: prompts, directory: directory)
    let source = Capture()
    recorder.keepAudio = true
    recorder.start(source: source, first: FakeEngine(id: "one", script: [.final("invented")]),
        second: FakeEngine(id: "two", script: [.final("invented")]), vocabulary: .init(userID: "fixture", terms: []),
        device: "Linux synthetic", captureKind: .synthetic, cloudConsent: false, synthetic: true)
    for _ in 0..<2000 { if source.starts > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
    source.channel.continuation.yield(.frame(try AudioFrame(samples: [1], timestamp: 0))); recorder.finish()
    for _ in 0..<2000 { if !recorder.busy { break }; try await Task.sleep(for: .milliseconds(1)) }
    _ = try recorder.prepareExport(); try recorder.exportCompleted(success: true)
    let abandoned = directory.appendingPathComponent("abandoned.pcm")
    try Data([0]).write(to: abandoned)
    _ = try BenchmarkRecorder(prompts: prompts, directory: directory)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(remaining.contains { $0.hasSuffix(".kept") })
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
}

@Test @MainActor func suggestionTargetChangeNeedsReviewThenAnExplicitApprovalTap() async throws {
    let rig = try Rig(); try await rig.record(mode: .ai_control)
    #expect(rig.model.controls.target == .auto)
    let card = try #require(rig.model.suggestions.first)
    await rig.model.review(card)
    #expect(rig.model.controls.target == .auto)
    let request = try #require(rig.model.approval?.id)
    await rig.model.approve()
    #expect(rig.model.controls.target == .device("phone"))
    #expect(rig.gate.state(requestID: request) == .succeeded)
    #expect(rig.bio.count == 0)
}

@Test @MainActor func portableStateObservationPublishesModeAndDestinationChanges() throws {
    let rig = try Rig()
    var changes = 0
    rig.model.onStateChange = { changes += 1 }
    rig.model.setTarget(.device("phone"))
    rig.model.setMode(.ai_control)
    #expect(changes > 0)
    #expect(rig.model.destination?.device_id == "phone")
    #expect(rig.model.controls.mode == .ai_control)
}

@Test @MainActor func rapidStopAndRestartKeepsTheCurrentMicrophoneHandle() async throws {
    var sources: [Capture] = []
    let rig = try Rig(captureFactory: {
        let source = Capture(); sources.append(source); return source
    })
    for _ in 0..<25 {
        rig.model.setCapture(.continuous)
        try await rig.until { rig.model.isRecording }
        rig.model.finishUtterance()
        rig.model.stop()
    }
    rig.model.setCapture(.continuous)
    try await rig.until { rig.model.isRecording }
    for _ in 0..<20 { await Task.yield() }
    rig.model.stop()
    let allStopped = sources.allSatisfy { $0.stopped }
    #expect(allStopped)
}

@Test @MainActor func failedHoldCannotReopenFromTimerTicksWithoutFreshPress() async throws {
    var attempts = 0
    let rig = try Rig(captureFactory: {
        attempts += 1
        let capture = Capture(); capture.failStart = true; return capture
    })
    rig.model.setCapture(.hold); rig.model.press(at: 0); rig.model.advanceTrigger(to: 300)
    try await rig.until { rig.model.listening == .failed }
    rig.model.advanceTrigger(to: 325)
    for _ in 0..<20 { await Task.yield() }
    #expect(attempts == 1)
    rig.model.release(at: 400)
    rig.model.press(at: 500); rig.model.advanceTrigger(to: 800)
    try await rig.until { attempts == 2 }
    rig.model.stop()
}

@Test @MainActor func autoDestinationUpdatesListeningPresentationBetweenSlices() async throws {
    let rig = try Rig()
    let computer = DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Fixture PC", platform: .windows,
        role: .both, capabilities: [.receive_text, .open_resource, .delegate_task])
    try await rig.registry.register(computer)
    var names: [String] = []
    rig.model.stateDidChange = { recording, name in if recording { names.append(name) } }
    rig.model.setCapture(.continuous); try await rig.until { rig.model.isRecording }
    func slice(_ time: Double) throws {
        rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [1000], timestamp: time)))
        rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: Array(repeating: 0, count: 12_800), timestamp: time + 0.01)))
    }
    try slice(0); try await rig.until { rig.model.history.count == 1 }
    try rig.model.updateFocus(FocusReport(account_id: "fixture", device_id: "pc", text_field_focused: true, last_activity_at: 1_000_000, activity_age_ms: 0))
    try slice(1); try await rig.until { rig.model.history.count == 2 }
    #expect(names.last == "Fixture PC")
    rig.model.stop()
}

@Test @MainActor func failedQueueCanRetryRetainedPermitWithRealRouter() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var router: TaskRouter?
    var fail = true
    let destination = Destination(id: "phone", session: .init(provider: "desktop", account: "fixture", host: "phone",
        workspace: "default", providerSessionID: "machine", capabilityProfile: "paired"), capabilities: [.open_resource], available: false)
    let rig = try Rig(tool: .openResourceTool(.init(account_id: "fixture", device_id: "phone", resource_uri: "https://example.invalid/fixture")), delivery: { permit in
        if fail { throw RouterError.persistence }
        var rules = RoutingRules(project: "default"); rules.selectedTarget = "phone"
        rules.capability = .open_resource; rules.machineDependency = "phone"
        _ = try router!.enqueue(permit, rules: rules, destinations: [destination])
        return router!.snapshot()
    })
    router = try TaskRouter(store: FileTaskQueueStore(url: directory.appendingPathComponent("queue.json")), policy: rig.gate)
    try await rig.record(mode: .ai_control)
    await rig.model.review(try #require(rig.model.suggestions.first)); await rig.model.approve()
    #expect(rig.model.message?.contains("Queue confirmation failed") == true)
    fail = false; await rig.model.approve()
    #expect(router?.snapshot().count == 1)
    #expect(rig.model.approval == nil)
}
