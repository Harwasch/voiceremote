// Purpose: push and audit adapter integrity, BLE source/gesture boundaries.
// Inputs: synthetic metadata/PCM and in-memory transport; no device/service claim.
import Foundation
import Testing
import Crypto
import Core
import Stt
@testable import Policy
import Pairing
import TrustedInput
import VoiceRemoteProtocol
@testable import AppModel

@MainActor private final class PhoneArchiveStore: AuditArchiveAnchorStore {
    var value = AuditArchiveState(anchor: AuditArchiveAnchor(account: "fixture", room: String(repeating: "a", count: 32)))
    func loadArchive() -> AuditArchiveState { value }
    func saveArchive(_ value: AuditArchiveState) { self.value = value }
}
@MainActor private final class RecoveryCheckpoint: AuditRecoveryCheckpointStore {
    let recoverySlotID = UUID().uuidString
    var value = AuditCheckpoint.empty
    var pending: AuditPending?
    func load() -> AuditCheckpoint { value }
    func save(_ value: AuditCheckpoint) { self.value = value }
    func loadPending() -> AuditPending? { pending }
    func savePending(_ value: AuditPending?) { pending = value }
}
@MainActor private final class LostArchive: AuditArchiveClient {
    func append(_ block: AuditArchiveBlock) async throws {}
    func read(account: String, room: String, sequence: Int64) async throws -> [AuditArchiveBlock] { [] }
}

@Test @MainActor func productionPhoneAEADAuthenticatesNonceContextAndKey() throws {
    let cipher = try PhoneArchiveCipher(key: Data(repeating: 7, count: 32))
    let bytes = Data(repeating: 42, count: 2048), context = Data("synthetic context".utf8)
    let first = try cipher.seal(bytes, context: context), second = try cipher.seal(bytes, context: context)
    #expect(first != second)
    #expect(try cipher.open(first, context: context) == bytes)
    #expect(throws: (any Error).self) { try cipher.open(first, context: Data("other tenant".utf8)) }
    var changed = first; changed[changed.count - 1] ^= 1
    #expect(throws: (any Error).self) { try cipher.open(changed, context: context) }
    let wrongKey = try PhoneArchiveCipher(key: Data(repeating: 8, count: 32))
    #expect(throws: (any Error).self) { try wrongKey.open(first, context: context) }
}

@Test @MainActor func archiveReadBackLossIsDurableAndCannotBePresentedAsUploadSuccess() async throws {
    let log = try AuditLog(journal: Journal(), checkpoints: Checkpoint(), retention: AuditRetention())
    let store = PhoneArchiveStore()
    let client = LostArchive(), cipher = try PhoneArchiveCipher(key: Data(repeating: 1, count: 32))
    try await AuditArchive.verifyScheduled(client: client, cipher: cipher, store: store, now: 1_000_000)
    #expect(store.value.health == .verified) // Empty check is not a first-upload check.
    try log.append(event: .denied, subject: "synthetic", payloadHash: "fixture", actor: "owner", now: 1_000_000)
    do {
        _ = try await PhoneArchiveMaintenance.replicate(log: log, client: client,
            cipher: cipher, store: store, now: 1_000_001)
        Issue.record("Acknowledgement without retained ciphertext was accepted")
    } catch { #expect(store.value.health == .lostCopy) }
    #expect(log.records.count == 1)
}

@Test @MainActor func phoneRecoveryRequiresFreshBiometricAndPreservesDamagedOriginal() async throws {
    let original = Journal(), cp = Checkpoint(), destination = Journal(), target = RecoveryCheckpoint()
    let log = try AuditLog(journal: original, checkpoints: cp, retention: AuditRetention())
    try log.append(event: .denied, subject: "synthetic", payloadHash: "fixture", actor: "owner", now: 1_000_000)
    let client = FakeAuditArchiveClient(), store = PhoneArchiveStore()
    let cipher = try PhoneArchiveCipher(key: Data(repeating: 1, count: 32)), bio = Bio()
    _ = try await AuditArchive.replicate(log: log, client: client, cipher: cipher, store: store, now: 1_000_000)
    original.data.removeLast(); let damaged = original.data
    bio.allowed = false
    do {
        _ = try await PhoneArchiveRecovery.restore(client: client, cipher: cipher, archive: store,
            source: original, checkpoints: cp, destination: destination, destinationCheckpoints: target,
            account: "fixture", actor: "owner", sessionID: "recovery", biometric: bio, now: { 1_000_000 })
        Issue.record("Recovery bypassed biometric denial")
    } catch { #expect(bio.count == 1); #expect(target.value == .empty); #expect(destination.data.isEmpty) }
    bio.allowed = true
    let restored = try await PhoneArchiveRecovery.restore(client: client, cipher: cipher, archive: store,
        source: original, checkpoints: cp, destination: destination, destinationCheckpoints: target,
        account: "fixture", actor: "owner", sessionID: "recovery", biometric: bio, now: { 1_000_000 })
    #expect(bio.count == 2); #expect(restored.records.last?.event == .recovered)
    #expect(original.data == damaged); #expect(cp.value.retired == true)
    let resumed = try await PhoneArchiveRecovery.restore(client: client, cipher: cipher, archive: store,
        source: original, checkpoints: cp, destination: destination, destinationCheckpoints: target,
        account: "fixture", actor: "owner", sessionID: "recovery", biometric: bio, now: { 1_000_000 })
    #expect(bio.count == 3); #expect(resumed.records.last?.event == .recovered)
    #expect(original.data == damaged)
}

@Test func wakePayloadIsOnlyAHintAndCannotCarryContent() {
    #expect(PhoneWake.isHint(Data(#"{"aps":{"content-available":1}}"#.utf8)))
    for payload in [#"{"aps":{"content-available":true}}"#, #"{"aps":{"content-available":1},"task":"synthetic"}"#,
                    #"{"aps":{"content-available":1,"alert":"synthetic"}}"#, #"{}"#] {
        #expect(!PhoneWake.isHint(Data(payload.utf8)))
    }
}

private func input(_ seq: UInt32, _ tick: UInt32, _ event: UInt8, _ capture: UInt8 = 1, _ mode: UInt8 = 0, _ pressed: Bool = false) throws -> RemoteInput {
    var bytes = Data()
    for word in [seq, tick] { bytes.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }) }
    bytes.append(contentsOf: [event, capture, mode, pressed ? 1 : 0, 0, 0])
    return try RemoteInput(bytes)
}
@Test func remoteSnapshotsShortTapsClockWrapAndModeChangesHaveNoApprovalPath() throws {
    var controls = RemoteControls()
    #expect(controls.accept(try input(0, UInt32.max - 102, 0, 2), edge: false) == [.stop, .positions(.continuous, .dictation)])
    _ = controls.accept(try input(1, UInt32.max - 101, 4), edge: true)
    #expect(controls.accept(try input(2, UInt32.max - 100, 1, 1, 0, true), edge: true).contains(.startHold))
    #expect(controls.accept(try input(3, 198, 2), edge: true).contains(.releaseHold(false)))
    _ = controls.accept(try input(4, 200, 1, 1, 0, true), edge: true)
    #expect(controls.accept(try input(5, 500, 2), edge: true).contains(.releaseHold(true)))
    #expect(controls.accept(try input(6, 501, 5, 1, 1), edge: true) == [.boundary, .positions(.hold, .ai_control)])
    #expect(controls.accept(try input(7, 502, 3, 1, 1), edge: true).contains(.cycleTarget))
    controls.reset()
    _ = controls.accept(try input(0, 0, 0, 1, 0, true), edge: false)
    #expect(!controls.accept(try input(1, 301, 1, 1, 0, true), edge: true).contains(.startHold))
}

@Test func remoteProvisionalAudioAndMeasuredSourceLossStayIsolated() throws {
    var hold = RemoteHoldBuffer(provisional: true)
    let frame = try AudioFrame(samples: [0, 32767, -32768, 100], timestamp: 0)
    #expect(try hold.frame(frame).isEmpty)
    #expect(hold.qualify() == [.frame(frame)])
    let phone = CaptureMetrics(), remote = CaptureMetrics()
    phone.observe(.frame(frame)); remote.observe(.frame(frame)); remote.observe(.interrupted)
    #expect(throws: (any Error).self) { try CaptureMetrics.select(choice: .automatic, remoteReady: true,
        phone: phone.quality(id: "phone"), remote: remote.quality(id: "remote")) }
    #expect(throws: (any Error).self) { try CaptureMetrics.select(choice: .remote, remoteReady: false, phone: nil, remote: nil) }
    #expect(remote.quality(id: "remote")?.dropouts == 1)
    #expect(remote.quality(id: "remote")?.clipping == 0.5)
    #expect(CaptureMetrics.current(phone.quality(id: "phone"), recordedIdentity: "old-headset", currentIdentity: "new-route") == nil)
    #expect(CaptureMetrics.current(remote.quality(id: "remote"), recordedIdentity: "m5-enrollment", currentIdentity: "waveshare-enrollment") == nil)
    #expect(CaptureMetrics.current(phone.quality(id: "phone"), recordedIdentity: "route", currentIdentity: "route") != nil)
}

@Test func pttEdgesInRECDoNotStopContinuousCapture() throws {
    var controls = RemoteControls()
    _ = controls.accept(try input(0, 0, 0, 2), edge: false)
    #expect(controls.accept(try input(1, 100, 1, 2, 0, true), edge: true) == [.positions(.continuous, .dictation)])
    #expect(controls.accept(try input(2, 500, 2, 2), edge: true) == [.positions(.continuous, .dictation)])
}

@Test func audioStatusSnapshotsDoNotInvalidateTheArmingDisplayBarrier() throws {
    var tracker = RemoteInputTracker()
    _ = try tracker.accept(input(0, 0, 0))
    _ = try tracker.accept(input(1, 1, 1, 1, 0, true))
    let writtenRevision = tracker.controlRevision
    _ = try tracker.accept(input(2, 20, 0, 1, 0, true))
    #expect(tracker.controlRevision == writtenRevision)
    _ = try tracker.accept(input(3, 301, 2))
    #expect(tracker.controlRevision != writtenRevision)
}

@Test @MainActor func remotePositionsDoNotStartCaptureOrGrantPhonePTTAuthority() throws {
    let rig = try Rig()
    rig.model.remotePositions(capture: .continuous, mode: .ai_control)
    #expect(rig.capture.starts == 0); #expect(rig.model.listening == .idle)
    #expect(rig.execution.permits.isEmpty)
}

@Test @MainActor func targetCycleMatchesDisplayedOrderAndPreservesMode() async throws {
    let rig = try Rig()
    let devices = [DeviceInfo(account_id: "fixture", device_id: "z", display_name: "Last", platform: .windows, role: .both, capabilities: [.receive_text]),
        DeviceInfo(account_id: "fixture", device_id: "a", display_name: "First", platform: .linux, role: .text_receiver, capabilities: [.receive_text]),
        DeviceInfo(account_id: "fixture", device_id: "agent", display_name: "Agent", platform: .linux, role: .agent, capabilities: [.delegate_task])]
    for device in devices { try await rig.registry.register(device) }
    await rig.model.refresh()
    rig.model.remotePositions(capture: .hold, mode: .ai_control)
    for target in [TargetSelection.device("phone"), .device("a"), .device("z"), .auto] {
        rig.model.cycleRemoteTarget()
        #expect(rig.model.controls.target == target)
        #expect(rig.model.controls.mode == .ai_control)
    }
}

@Test @MainActor func modeBoundaryFinishesUnderPinnedOriginalMode() async throws {
    let rig = try Rig()
    rig.model.remotePositions(capture: .continuous, mode: .dictation)
    rig.model.begin(); try await rig.until { rig.model.isRecording }
    rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500, 200], timestamp: 0)))
    rig.model.finishUtterance()
    rig.model.remotePositions(capture: .continuous, mode: .ai_control)
    await rig.model.awaitRemoteBoundary()
    #expect(await rig.brain.calls == 0)
    #expect(rig.model.history.count == 1)
    #expect(rig.model.controls.mode == .ai_control)
}

@Test @MainActor func remoteTierThreeApprovalRemainsRefused() async throws {
    let log = try AuditLog(journal: Journal(), checkpoints: Checkpoint(), retention: AuditRetention()), bio = Bio()
    let gate = try PolicyGate(audit: log, biometric: bio, clock: { 1_000_000 })
    let input = PhoneInput(now: { 1_000_000 })
    let session = input.session(account: "fixture", actor: "owner", session: "synthetic", device: "phone", project: "fixture", destinationKind: .software)
    let activation = input.activation(session: session, kind: .inferred, expiresAt: 1_030_000)
    let tool = ToolCall.prepareSendTool(PrepareSendTool(account_id: "fixture", device_id: "phone", recipient: "synthetic", content: "synthetic"))
    guard case .suggestion(let preview) = gate.submit(try ProtocolCodec.encode(tool), input: activation) else { Issue.record("Missing preview"); return }
    let decision = await gate.approve(requestID: preview.requestID,
        evidence: input.approval(session: session, requestID: preview.requestID, payloadHash: preview.payloadHash, source: .remoteButton))
    if case .queued = decision { Issue.record("Remote tier 3 approval was accepted") }
    #expect(bio.count == 0)
}
