import Foundation
import Testing
import Core
import Router
import Policy
import Pairing
import VoiceRemoteProtocol
@testable import AppModel

@Test @MainActor func pressReleaseCancellationAndForegroundAreFailClosed() async throws {
    let rig = try Rig()
    rig.model.setCapture(.hold)
    rig.model.press(at: 0); rig.model.release(at: 100)
    #expect(rig.capture.starts == 0)
    rig.model.press(at: 1000); rig.model.advanceTrigger(to: 1300)
    try await rig.until { rig.model.isRecording }
    rig.model.cancelGesture()
    #expect(rig.capture.stopped)
    #expect(rig.model.controls.capture == .hold)
    rig.model.advanceTrigger(to: 1400)
    #expect(!rig.model.isRecording)
    rig.model.leaveForeground(); #expect(!rig.model.isRecording)
}

@Test @MainActor func settingsPersistBeforeAnyViewDisappears() throws {
    let rig = try Rig()
    var saved: AppSettings?
    rig.model.settingsDidChange = { saved = $0 }
    rig.model.settings.cloudConsent = true
    rig.model.settings.cloudConsent = false
    #expect(saved?.cloudConsent == false)
}

@Test func routePolicyDistinguishesLossFromConfiguration() {
    #expect(AudioRoutePolicy.action(for: .oldDeviceUnavailable) == .stop)
    #expect(AudioRoutePolicy.action(for: .categoryChanged) == .ignore)
    #expect(AudioRoutePolicy.action(for: .configurationChanged) == .restart)
    #expect(AudioRoutePolicy.action(for: .newDeviceAvailable) == .restart)
}

@Test @MainActor func coldIntentAndViewShareExactlyOneRuntime() throws {
    let bootstrap = RuntimeBootstrap<NSObject>()
    var starts = 0
    let intent = try bootstrap.resolve { starts += 1; return NSObject() }
    let view = try bootstrap.resolve { starts += 1; return NSObject() }
    #expect(intent === view); #expect(starts == 1)
}

@MainActor private final class PairingBackend: ComputerPairing {
    var beginWaiter: CheckedContinuation<String, Error>?
    var confirmWaiter: CheckedContinuation<DeviceInfo, Error>?
    var cancelled = 0
    var receivedRole: DeviceInfoRole?
    func begin(_ value: String, role: DeviceInfoRole) async throws -> String {
        receivedRole = role
        return try await withCheckedThrowingContinuation { beginWaiter = $0 }
    }
    func confirm(_ phrase: String) async throws -> DeviceInfo {
        try await withCheckedThrowingContinuation { confirmWaiter = $0 }
    }
    func cancel() async { cancelled += 1 }
}
@Test @MainActor func pairingCancelRejectsLatePhraseAndLateConfirmationError() async throws {
    let backend = PairingBackend(), flow: PairingFlow
    flow = PairingFlow(backend: backend); flow.role = .both
    let begin = Task { await flow.begin("synthetic-code") }
    while backend.beginWaiter == nil { await Task.yield() }
    await flow.cancel(); backend.beginWaiter?.resume(returning: "one two three four"); await begin.value
    #expect(flow.phrase == nil); #expect(!flow.busy); #expect(backend.receivedRole == .both)
    let next = Task { await flow.begin("new-synthetic-code") }
    backend.beginWaiter = nil
    while backend.beginWaiter == nil { await Task.yield() }
    backend.beginWaiter?.resume(returning: "one two three four"); await next.value
    let confirm = Task { await flow.confirm() }
    while backend.confirmWaiter == nil { await Task.yield() }
    await flow.cancel(); backend.confirmWaiter?.resume(throwing: PairingError.invalidState); _ = await confirm.value
    #expect(flow.error == nil); #expect(flow.phrase == nil)
}

@Test @MainActor func enrollmentAndRevocationSurviveRelaunchWithoutPersistingKeys() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("peers.json")
    let device = DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Fixture PC", platform: .windows,
        role: .both, capabilities: [.receive_text, .delegate_task, .open_resource])
    let first = try PeerStore(url: url, accountID: "fixture")
    try first.enroll(device, roomID: "fixture-room")
    let reopened = try PeerStore(url: url, accountID: "fixture")
    #expect(reopened.active.map(\.device) == [device])
    try reopened.markRevoked(deviceID: "pc", notificationPending: true)
    let revoked = try PeerStore(url: url, accountID: "fixture")
    #expect(revoked.active.isEmpty); #expect(revoked.records.first?.notificationPending == true)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("publicKey"))
}

@Test @MainActor func registeredDestinationQueuesWithRealRouterAndVisibleHold() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var router: TaskRouter?
    var devices: [DeviceInfo] = []
    let rig = try Rig(tool: .openResourceTool(.init(account_id: "fixture", device_id: "pc", resource_uri: "https://example.invalid/fixture")), delivery: { permit in
        try RegisteredRouting.enqueue(permit, devices: devices, router: router!)
        return router!.snapshot()
    })
    try await rig.registry.register(DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Fixture PC", platform: .windows,
        role: .both, capabilities: [.receive_text, .open_resource]))
    devices = await rig.registry.all()
    await rig.model.refresh()
    router = try TaskRouter(store: FileTaskQueueStore(url: root.appendingPathComponent("queue.json")), policy: rig.gate)
    try await rig.record(mode: .ai_control)
    await rig.model.review(try #require(rig.model.suggestions.first))
    _ = try #require(rig.model.approval)
    await rig.model.approve()
    let task = try #require(router?.snapshot().first)
    #expect(task.hold == .machineRequired)
    #expect(task.permittedDestinations.first?.id == "pc")
    #expect(rig.model.approval == nil)
}

@Test func blePhoneStateUsesCurrentTargetAndConservativeNonLongWriteBudget() throws {
    var controls = AppState(); controls.setCapture(.hold); controls.setTarget(.device("pc"))
    let pc = DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Fixture PC", platform: .windows,
        role: .text_receiver, capabilities: [.receive_text])
    let state = try RemotePhoneState.presentation(controls: controls, devices: [pc], phoneID: "phone", destination: pc,
        recording: true, acknowledgedSequence: 42, arm: true)
    #expect(state.names == ["Auto", "iPhone", "Fixture PC"]); #expect(state.activeIndex == 2); #expect(state.arm)
    let fragments = try state.fragments(transaction: 1, budget: RemotePhoneState.writeBudget(osMaximum: 512))
    #expect(fragments.allSatisfy { $0.count <= 20 })
}

@Test func bleOffPresentationNeverReportsRecordingOrArms() throws {
    let state = try RemotePhoneState.presentation(controls: AppState(), devices: [], phoneID: "phone", destination: nil,
        recording: true, acknowledgedSequence: 0, arm: true)
    #expect(state.recording == 0); #expect(!state.arm)
    _ = try state.fragments(transaction: 0, budget: 20)
}

@Test @MainActor func cancellingAnActiveGestureStopsEvenLockedCapture() async throws {
    let rig = try Rig()
    rig.model.setCapture(.continuous); try await rig.until { rig.model.isRecording }
    rig.model.press(at: 0); rig.model.cancelGesture()
    #expect(!rig.model.isRecording); #expect(rig.capture.stopped)
}
