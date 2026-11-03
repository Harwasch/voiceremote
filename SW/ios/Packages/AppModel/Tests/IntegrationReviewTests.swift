import Foundation
import Testing
import Pairing
import Core
import VoiceRemoteProtocol
@testable import AppModel

@Test func remoteEnrollmentRequiresBothNumericConfirmationsAndProtectedAccess() async throws {
    let keys = InMemoryKeyStore(), peripheral = UUID()
    let pins = RemoteEnrollmentStore(store: keys)
    #expect(try await pins.identity(peripheralID: peripheral, protectedAccess: true) == nil)
    for (access, system, remote) in [(false, "123456", "123456"), (true, "123456", "654321"), (true, "", ""), (true, "abcdef", "abcdef")] {
        await #expect(throws: (any Error).self) { try await pins.confirm(peripheralID: peripheral, protectedAccess: access, systemCode: system, remoteCode: remote) }
    }
    let identity = try await pins.confirm(peripheralID: peripheral, protectedAccess: true, systemCode: "123456", remoteCode: "123456")
    let reopened = RemoteEnrollmentStore(store: keys)
    #expect(try await reopened.identity(peripheralID: peripheral, protectedAccess: true) == identity)
    #expect(try await reopened.identity(peripheralID: peripheral, protectedAccess: false) == nil)
    #expect(try await reopened.identity(peripheralID: UUID(), protectedAccess: true) == nil)
    try await reopened.revoke(peripheralID: peripheral)
    #expect(try await reopened.identity(peripheralID: peripheral, protectedAccess: true) == nil)
}
@Test func desktopInsertionStatusCorrelatesSegmentAndAuthenticatedTarget() async throws {
    let history = try AppHistoryStore(now: 1000)
    let entry = HistoryEntry(segmentID: "segment-fixture", targetID: "desktop", text: "Invented.", createdAt: 1000)
    try await history.saveText(entry, state: .unconfirmed, now: 1000)
    let failed = TaskStatus(account_id: "fixture", command_id: entry.segmentID, execution_state: .failed, updated_at: 1000, outcome: .unavailable)
    try await history.insertionStatus(failed, from: "other", accountID: "fixture")
    #expect(await history.deliveryStates()[entry.segmentID] == .unconfirmed)
    try await history.insertionStatus(failed, from: "desktop", accountID: "other-account")
    #expect(await history.deliveryStates()[entry.segmentID] == .unconfirmed)
    try await history.insertionStatus(failed, from: "desktop", accountID: "fixture")
    try await history.finishDelivery(id: entry.segmentID, phone: false)
    #expect(await history.deliveryStates()[entry.segmentID] == .failed)
    let uncertain = TaskStatus(account_id: "fixture", command_id: entry.segmentID, execution_state: .failed, updated_at: 1001, outcome: .error)
    try await history.insertionStatus(uncertain, from: "desktop", accountID: "fixture")
    #expect(await history.deliveryStates()[entry.segmentID] == .unconfirmed)
}
@Test @MainActor func relaySuspensionPersistsWithoutRemovingEnrollmentOrKeys() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let keys = InMemoryKeyStore(); keys.put("signing", value: Data(repeating: 1, count: 32))
    let store = try PeerStore(url: url, accountID: "fixture")
    let device = DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic PC", platform: .linux, role: .text_receiver, capabilities: [.receive_text])
    try store.enroll(device, roomID: "room")
    try store.suspend(deviceID: "desktop")
    let reopened = try PeerStore(url: url, accountID: "fixture")
    #expect(reopened.active.count == 1); #expect(reopened.active.first?.suspended == true)
    #expect(keys.get("signing")?.count == 32)
    try reopened.suspend(deviceID: "desktop", false)
    #expect(reopened.active.first?.suspended == false)
}
@Test func namespacedHistoryIDsHaveStableChunkIdentity() {
    let offline = "offline-synthetic-42"
    #expect(HistoryTextIdentity.copyID(offline) == HistoryTextIdentity.copyID(offline))
    #expect(HistoryTextIdentity.copyID(offline) != HistoryTextIdentity.copyID(offline + "1"))
}

@Test func positiveDictationOutcomeIsAuthenticatedAndSurvivesRestart() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let history = try AppHistoryStore(url: url, now: 1000)
    let entry = HistoryEntry(segmentID: "positive-fixture", targetID: "desktop", text: "Synthetic.", createdAt: 1000)
    try await history.saveText(entry, state: .unconfirmed, now: 1000)
    let reply = DictationOutcome(account_id: "fixture", segment_id: entry.segmentID, target_device_id: "desktop", outcome: .inserted)
    try await history.dictationOutcome(reply, from: "other", accountID: "fixture")
    try await history.dictationOutcome(reply, from: "desktop", accountID: "other")
    #expect(await history.deliveryStates()[entry.segmentID] == .unconfirmed)
    try await history.dictationOutcome(reply, from: "desktop", accountID: "fixture")
    let reopened = try AppHistoryStore(url: url, now: 1001)
    #expect(await reopened.deliveryStates()[entry.segmentID] == .delivered)
    // A delayed failure cannot downgrade a proven insertion.
    try await history.dictationOutcome(DictationOutcome(account_id: "fixture", segment_id: entry.segmentID, target_device_id: "desktop", outcome: .unavailable), from: "desktop", accountID: "fixture")
    #expect(await history.deliveryStates()[entry.segmentID] == .delivered)
}

@Test @MainActor func captureControlCorrelatesExpiresAndNeverReplaysOrEnablesAI() async throws {
    let rig = try Rig(), connection = UUID()
    func request(_ id: String, state: CaptureState = .continuous) -> CaptureControl {
        CaptureControl(account_id: "fixture", request_id: id, target_device_id: "phone", capture_state: state, ttl_ms: 2000)
    }
    let expired = await rig.model.captureControl(request("expired"), connectionID: connection, receivedAt: .now - .seconds(3))
    #expect(expired.outcome == .expired); #expect(rig.capture.starts == 0)
    let started = await rig.model.captureControl(request("start"), connectionID: connection)
    #expect(started.outcome == .applied); #expect(started.request_id == "start"); #expect(rig.model.isRecording)
    rig.model.stop()
    let replay = await rig.model.captureControl(request("start"), connectionID: connection)
    #expect(replay.outcome == .cancelled); #expect(rig.capture.starts == 1)
    rig.model.setMode(.ai_control)
    let denied = await rig.model.captureControl(request("ai"), connectionID: connection)
    #expect(denied.outcome == .unavailable); #expect(!rig.model.isRecording)
}

@Test @MainActor func captureControlReportsUnavailableAndCancellationDuringPreparation() async throws {
    let failed = try Rig(); failed.capture.failStart = true
    let request = CaptureControl(account_id: "fixture", request_id: "failure", target_device_id: "phone", capture_state: .continuous, ttl_ms: 2000)
    let refused = await failed.model.captureControl(request, connectionID: UUID())
    #expect(refused.outcome == .unavailable); #expect(!failed.model.isRecording)
    let slow = try Rig(captureFactory: { try await Task.sleep(for: .seconds(1)); return Capture() })
    let task = Task { await slow.model.captureControl(request, connectionID: UUID()) }
    try await Task.sleep(for: .milliseconds(20)); slow.model.stop()
    let result = await task.value
    #expect(result.outcome == .cancelled); #expect(!slow.model.isRecording)
}
