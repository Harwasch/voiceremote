// Purpose: regressions from push/BLE cross review; synthetic controls and Apple wiring.
// Inputs: BLE contract revision and production source; Apple SDK execution unverified.
import Foundation
import Testing
import Core
import VoiceRemoteProtocol
import Policy
import Stt
@testable import AppModel

func reviewInput(_ sequence: UInt32, event: UInt8, capture: UInt8 = 2, mode: UInt8 = 0, pressed: Bool = false) throws -> RemoteInput {
    var bytes = Data()
    for word in [sequence, sequence &* 100] {
        bytes.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
    }
    bytes.append(contentsOf: [event, capture, mode, pressed ? 1 : 0, 0, 0])
    return try RemoteInput(bytes)
}
@Test func reviewModeFlipAfterPhoneStopOrReconnectDoesNotStartREC() throws {
    var controls = RemoteControls()
    _ = controls.accept(try reviewInput(0, event: 0), edge: false)
    #expect(!controls.accept(try reviewInput(1, event: 5, mode: 1), edge: true).contains(.startContinuous))
}
@Test func reviewFirstPressAfterTargetCycleIsAccepted() throws {
    var controls = RemoteControls()
    _ = controls.accept(try reviewInput(0, event: 0, capture: 1), edge: false)
    _ = controls.accept(try reviewInput(1, event: 3, capture: 1), edge: true)
    #expect(controls.accept(try reviewInput(2, event: 1, capture: 1, pressed: true), edge: true).contains(.startHold))
}
@Test func reviewBackgroundResumeExcludesBiometricAndControlCenterTransitions() {
    var lifecycle = PhoneSceneLifecycle()
    func transition(to phase: PhoneScenePhase) -> Bool { lifecycle.transition(to: phase) }
    #expect(!transition(to: .active))
    for _ in 0..<3 {
        #expect(!transition(to: .inactive))
        #expect(!transition(to: .active))
    }
    #expect(!transition(to: .background))
    #expect(!transition(to: .inactive))
    #expect(transition(to: .active))
    #expect(!transition(to: .active))
}
@Test func reviewModeFlipRestartsOnlyAnExistingRECAndFreshRECStillStarts() throws {
    var controls = RemoteControls()
    _ = controls.accept(try reviewInput(0, event: 0), edge: false)
    #expect(controls.accept(try reviewInput(1, event: 5, mode: 1), edge: true, recording: true).contains(.startContinuous))
    #expect(!controls.accept(try reviewInput(2, event: 5), edge: true, recording: false).contains(.startContinuous))
    #expect(controls.accept(try reviewInput(3, event: 4), edge: true).contains(.startContinuous))
}
@Test func reviewHeldPTTStatusSnapshotsPermitOlderControlAcknowledgement() throws {
    var tracker = RemoteInputTracker()
    _ = try tracker.accept(reviewInput(0, event: 0, capture: 1))
    _ = try tracker.accept(reviewInput(1, event: 1, capture: 1, pressed: true))
    _ = try tracker.accept(reviewInput(2, event: 0, capture: 1, pressed: true))
    _ = try tracker.accept(reviewInput(3, event: 0, capture: 1, pressed: true))
    #expect(tracker.canArm(acknowledging: 1))
    #expect(tracker.canArm(acknowledging: 2))
    #expect(!tracker.canArm(acknowledging: 0))
    #expect(!tracker.canArm(acknowledging: 4))
    _ = try tracker.accept(reviewInput(4, event: 2, capture: 1))
    #expect(!tracker.canArm(acknowledging: 1))
    #expect(tracker.canArm(acknowledging: 4))
    tracker.reset()
    _ = try tracker.accept(reviewInput(UInt32.max - 1, event: 0, capture: 1))
    _ = try tracker.accept(reviewInput(UInt32.max, event: 1, capture: 1, pressed: true))
    _ = try tracker.accept(reviewInput(0, event: 0, capture: 1, pressed: true))
    #expect(tracker.canArm(acknowledging: UInt32.max))
    #expect(!tracker.canArm(acknowledging: UInt32.max - 1))
    #expect(!tracker.canArm(acknowledging: 1))
}
@Test @MainActor func reviewTriggerPinsCaptureBeforeMetricsOrSelectionCanChange() async throws {
    let phone = Capture(), remote = Capture()
    var remoteWasBest = true
    let rig = try Rig(captureFactory: { phone })
    rig.model.pinCapture = {
        let pinned = remoteWasBest
        return { pinned ? remote : phone }
    }
    rig.model.remotePositions(capture: .hold, mode: .dictation)
    rig.model.begin()
    remoteWasBest = false // Metric expiry while target/model setup is suspended.
    try await rig.until { rig.model.isRecording }
    #expect(remote.starts == 1); #expect(phone.starts == 0)
    rig.model.stop()
    // A deliberate remote press supplies its own source even with no metrics.
    rig.model.remotePositions(capture: .hold, mode: .dictation)
    let second = Capture()
    rig.model.begin(capture: { second })
    try await rig.until { rig.model.isRecording }
    #expect(second.starts == 1); #expect(phone.starts == 0)
    rig.model.stop()
}
@Test @MainActor func reviewPhoneStopCancelsAPendingRECModeRestartEvenAfterSnapshots() async throws {
    let capture = Capture(), rig = try Rig(captureFactory: { capture })
    rig.model.remotePositions(capture: .continuous, mode: .dictation)
    let pending = rig.model.captureGeneration
    rig.model.stop()
    // A later physical-position snapshot can update controls, but cannot renew
    // the mode-change restart which was already cancelled by the phone.
    rig.model.remotePositions(capture: .continuous, mode: .ai_control)
    rig.model.beginRemote(capture: { capture }, generation: pending)
    for _ in 0..<20 { await Task.yield() }
    #expect(capture.starts == 0)
    #expect(rig.model.listening == .idle)
}
@Test func reviewUnenrolledHandshakeContainsNoDestinationLabels() throws {
    let safe = RemotePhoneState.enrollmentState
    let bytes = try safe.fragments(transaction: 1, budget: 20).reduce(into: Data()) { $0.append($1.dropFirst(6)) }
    #expect(safe.names == ["Auto"]); #expect(!safe.arm)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("iPhone"))
    var info = Data([1,1,1,0,0,1,0,0,63,0,1,1,240,0,24,1,0,2,0,0])
    info[0] = 2
    do { _ = try RemoteInfo(info); Issue.record("Wrong major accepted") }
    catch { #expect(RemoteFailurePresentation.message(for: error).contains("Incompatible")) }
}
@Test @MainActor func reviewBackgroundActivityFailureCannotInterruptCapture() async throws {
    let rig = try Rig()
    rig.model.remotePositions(capture: .hold, mode: .dictation); rig.model.begin()
    try await rig.until { rig.model.isRecording }
    let id = ListeningPresentation.request { throw SttFailure.unavailable }
    #expect(id == nil); #expect(rig.model.isRecording); #expect(!rig.capture.stopped)
    rig.model.leaveForeground()
    #expect(rig.model.isRecording) // A remote hold is independent of a UIKit gesture.
    rig.model.stop()
}
@Test @MainActor func reviewPhoneHoldPinsAtPressBeforeQualification() async throws {
    let phone = Capture(), remote = Capture(), rig = try Rig(captureFactory: { phone })
    var chooseRemote = true
    rig.model.pinCapture = { let selected = chooseRemote; return { selected ? remote : phone } }
    rig.model.setCapture(.hold); rig.model.press(at: 0)
    chooseRemote = false
    rig.model.advanceTrigger(to: 300)
    try await rig.until { rig.model.isRecording }
    #expect(remote.starts == 1); #expect(phone.starts == 0)
    rig.model.stop()
}
@Test @MainActor func reviewRemotePressCannotBorrowAnOverlappingPhoneGestureGrant() async throws {
    let rig = try Rig()
    rig.model.setTarget(.device("phone"))
    rig.model.grantTargetSelection(device: try #require(rig.model.destination), project: "default")
    rig.model.remotePositions(capture: .hold, mode: .ai_control)
    rig.model.press(at: 0) // Phone gesture has not yet qualified.
    rig.model.beginRemote(capture: { rig.capture }) // A separate remote press arrives.
    try await rig.until { rig.model.isRecording }
    rig.model.release(at: 500)
    #expect(rig.model.isRecording)
    rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [1000], timestamp: 0)))
    rig.model.finishUtterance(); await rig.model.awaitRemoteBoundary()
    await rig.model.review(try #require(rig.model.suggestions.first))
    #expect(rig.model.approval != nil)
}
@Test @MainActor func reviewEmptyLegacyJournalMigratesButMissingAnchorsNeverBlessNonemptyHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("audit.jsonl")
    try Data().write(to: url)
    let initial = try AuditCheckpointBootstrap.initial(markerExists: false, journal: Data(contentsOf: url), pendingExists: false, legacySlot: true)
    #expect(initial == .empty)
    let cp = Checkpoint(); cp.save(initial)
    let log = try AuditLog(journal: FileAuditJournal(url: url), checkpoints: cp, retention: AuditRetention())
    #expect(log.records.isEmpty)
    #expect(throws: (any Error).self) { try AuditCheckpointBootstrap.initial(markerExists: false,
        journal: Data("synthetic nonempty history".utf8), pendingExists: false, legacySlot: true) }
    #expect(throws: (any Error).self) { try AuditCheckpointBootstrap.initial(markerExists: true,
        journal: Data(), pendingExists: false, legacySlot: true) }
    #expect(throws: (any Error).self) { try AuditCheckpointBootstrap.initial(markerExists: false,
        journal: Data(), pendingExists: true, legacySlot: true) }
    #expect(PhoneArchiveMaintenance.status(roomCount: 0, messages: ["Audit copy verified by read-back."]).contains("No relay audit copy"))
}
private func appleSource(_ name: String) throws -> String {
    let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: ios.appendingPathComponent("App/" + name), encoding: .utf8)
}
@Test func reviewAppleWiringDoesNotUseTheKnownUnsafeBranches() throws {
    let scene = try appleSource("VoiceRemoteApp.swift"), ble = try appleSource("RemoteBLELink.swift")
    let runtime = try appleSource("AppRuntime.swift"), activity = try appleSource("ListeningActivity.swift")
    #expect(!scene.contains("if phase == .active {"))
    #expect(!ble.contains("acknowledgedSequence != tracker.last?.sequence"))
    #expect(!ble.contains("host.selectedRemote {"))
    #expect(ble.contains("guard authenticatedEnrollment"))
    #expect(ble.contains("RemotePhoneState.enrollmentState"))
    #expect(ble.contains("RemoteFailurePresentation"))
    #expect(runtime.contains("pinnedCapture"))
    #expect(scene.contains("activeSourceDisplay"))
    #expect(!runtime.contains("guard !rooms.isEmpty else { return }"))
    #expect(!activity.contains("catch { AppRuntime.shared?.model.interrupt() }"))
}
