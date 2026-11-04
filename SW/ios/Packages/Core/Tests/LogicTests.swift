import Foundation
import XCTest
import VoiceRemoteProtocol
@testable import Core

private actor RevocationSpy: DeviceRevocationHandler {
    var calls: [String] = []
    var failKey = false
    func setFailure() { failKey = true }
    func deleteKey(deviceID: String) throws { calls.append("key:" + deviceID); if failKey { throw CoreError.revokedDevice } }
    func dropRoom(deviceID: String) { calls.append("room:" + deviceID) }
}
private actor TextSpy: DictationTarget {
    var events: [String] = []
    var messages: [DictationText] = []
    func showTarget(_ device: DeviceInfo) { events.append("show:" + device.device_id) }
    func insert(_ text: DictationText) { events.append("insert:" + text.target_device_id); messages.append(text) }
}
private func device(_ id: String, role: DeviceInfoRole = .text_receiver, capabilities: [Capability] = [.receive_text], account: String = "test") -> DeviceInfo {
    DeviceInfo(account_id: account, device_id: id, display_name: id, platform: .ios, role: role, capabilities: capabilities)
}
private func focus(_ id: String, _ time: Int64, focused: Bool = true, account: String = "test") -> FocusReport {
    FocusReport(account_id: account, device_id: id, text_field_focused: focused, last_activity_at: time, activity_age_ms: 0)
}

final class LogicTests: XCTestCase, @unchecked Sendable {
    func testIdleHeartbeatCannotRefreshActivityDespiteClockSkew() throws {
        let clock = TestFocusClock(100_000)
        var picker = TargetPicker(accountID: "test", phoneID: "phone", clock: clock)
        let bytes = Data(#"{"kind":"focus_report","account_id":"test","device_id":"desktop","text_field_focused":true,"last_activity_at":9007199254740991,"activity_age_ms":61000}"#.utf8)
        try picker.update(ProtocolCodec.decode(FocusReport.self, from: bytes))
        XCTAssertEqual(try picker.resolve(devices: [device("desktop")]).device_id, "phone")
    }
    func testAutoRanksActivityAgeAcrossTwoDevicesAndIdleHeartbeats() throws {
        let clock = TestFocusClock(100_000)
        var picker = TargetPicker(accountID: "test", phoneID: "phone", clock: clock)
        func report(_ id: String, _ age: Int64, epoch: Int64) -> FocusReport {
            FocusReport(account_id: "test", device_id: id, text_field_focused: true, last_activity_at: epoch, activity_age_ms: age)
        }
        try picker.update(report("a", 500, epoch: 0))
        clock.set(100_100)
        try picker.update(report("b", 30_000, epoch: 9_007_199_254_740_991))
        XCTAssertEqual(try picker.resolve(devices: [device("a"), device("b")]).device_id, "a")
        clock.set(160_100)
        try picker.update(report("b", 90_000, epoch: 9_007_199_254_740_991))
        XCTAssertEqual(try picker.resolve(devices: [device("a"), device("b")]).device_id, "phone")
        // Legacy focus without an age is unknown; a heartbeat is not input.
        try picker.update(FocusReport(account_id: "test", device_id: "a", text_field_focused: true, last_activity_at: 0))
        XCTAssertEqual(try picker.resolve(devices: [device("a")]).device_id, "phone")
        try picker.update(report("a", 0, epoch: 0)); picker.clear("a")
        XCTAssertEqual(try picker.resolve(devices: [device("a")]).device_id, "phone")
    }
    func testModeCaptureAndTargetAreIndependent() {
        var state = AppState()
        XCTAssertEqual(state.mode, .dictation); XCTAssertEqual(state.capture, .off)
        for target in [TargetSelection.auto, .device("laptop")] {
            state.setTarget(target)
            for capture in [CaptureState.off, .hold, .continuous] {
                state.setCapture(capture)
                for mode in [Mode.ai_control, .dictation] {
                    state.setMode(mode)
                    XCTAssertEqual(state.target, target); XCTAssertEqual(state.capture, capture)
                }
            }
        }
    }
    func testHoldThresholdReleaseAndNoiseTaps() {
        var trigger = CaptureTrigger()
        trigger.press(at: 0); trigger.advance(to: 299)
        XCTAssertEqual(trigger.capture, .off)
        trigger.release(at: 299)
        trigger.press(at: 800); trigger.release(at: 1099)
        XCTAssertEqual(trigger.capture, .off) // taps outside the window do not lock
        trigger.press(at: 1200); trigger.advance(to: 1500)
        XCTAssertEqual(trigger.capture, .hold)
        trigger.advance(to: 1550); trigger.release(at: 1600)
        XCTAssertEqual(trigger.capture, .off)
    }
    func testDoubleEligibleTapLocksAndStopWorks() {
        var trigger = CaptureTrigger()
        trigger.press(at: 0); trigger.release(at: 100)
        trigger.press(at: 600); trigger.release(at: 700) // inclusive 500 ms gap
        XCTAssertEqual(trigger.capture, .continuous)
        trigger.press(at: 1200); trigger.release(at: 1499)
        XCTAssertEqual(trigger.capture, .continuous)
        trigger.press(at: 1500); trigger.release(at: 1800)
        XCTAssertEqual(trigger.capture, .off)
        trigger.press(at: 2000); trigger.advance(to: 2300); trigger.stop()
        XCTAssertEqual(trigger.capture, .off)
    }
    func testSlowOrOutOfOrderTriggersDoNotLock() {
        var trigger = CaptureTrigger()
        trigger.press(at: 0); trigger.release(at: 300)
        trigger.press(at: 801); trigger.release(at: 1101)
        XCTAssertEqual(trigger.capture, .off)
        trigger.press(at: 1100); trigger.release(at: 1099)
        XCTAssertEqual(trigger.capture, .off)
    }
    func testAutoNewestFocusWindowFallbackAndFixedChoice() throws {
        let devices = [device("phone"), device("laptop"), device("desktop"), device("agent", role: .agent)]
        let clock = TestFocusClock(40_000)
        var picker = TargetPicker(accountID: "test", phoneID: "phone", clock: clock)
        XCTAssertEqual(try picker.resolve(at: 100_000, devices: devices).device_id, "phone")
        try picker.update(focus("laptop", 9_007_199_254_740_991))
        XCTAssertEqual(try picker.resolve(at: 100_000, devices: devices).device_id, "laptop")
        XCTAssertEqual(try picker.resolve(at: 100_001, devices: devices).device_id, "phone")
        clock.set(99_000)
        try picker.update(focus("desktop", 0))
        clock.set(100_000)
        try picker.update(focus("agent", 100_000))
        XCTAssertEqual(try picker.resolve(devices: devices).device_id, "desktop")
        try picker.update(focus("desktop", 0, focused: false))
        XCTAssertEqual(try picker.resolve(devices: devices).device_id, "laptop")
        clock.set(100_001)
        XCTAssertEqual(try picker.resolve(devices: devices).device_id, "phone")
        picker.selection = .device("laptop")
        XCTAssertEqual(try picker.resolve(at: 999_999, devices: devices).device_id, "laptop")
        picker.selection = .device("agent")
        XCTAssertThrowsError(try picker.resolve(at: 100_000, devices: devices))
        XCTAssertThrowsError(try picker.update(focus("evil", 1, account: "other")))
    }
    func testFocusOrderingUsesLocalReceiptAndRevokedDevicesAreExcluded() throws {
        let clock = TestFocusClock(10)
        var picker = TargetPicker(accountID: "test", phoneID: "phone", clock: clock)
        try picker.update(focus("a", 999_999)); try picker.update(focus("b", 0))
        XCTAssertEqual(try picker.resolve(devices: [device("b"), device("a")]).device_id, "a")
        clock.set(11)
        try picker.update(focus("a", 0, focused: false))
        XCTAssertEqual(try picker.resolve(devices: [device("b"), device("a")]).device_id, "b")
        XCTAssertEqual(try picker.resolve(devices: []).device_id, "phone")
    }
    func testRegistryRolesCapabilitiesAccountAndRevocation() async throws {
        let spy = RevocationSpy()
        let registry = DeviceRegistry(accountID: "test", revocation: spy)
        try await registry.register(device("phone", role: .both, capabilities: [.receive_text, .external_send]))
        let registered = try await registry.textReceiver("phone")
        XCTAssertEqual(registered.role, .both); XCTAssertTrue(registered.capabilities.contains(.external_send))
        try await registry.register(device("agent", role: .agent))
        do { _ = try await registry.textReceiver("agent"); XCTFail() } catch {}
        do { try await registry.register(device("bad", account: "other")); XCTFail() } catch {}
        await spy.setFailure()
        do { try await registry.revoke("phone"); XCTFail() } catch {}
        let calls = await spy.calls
        XCTAssertEqual(calls, ["key:phone", "room:phone"])
        do { _ = try await registry.textReceiver("phone"); XCTFail() } catch {}
        do { try await registry.register(device("phone")); XCTFail() } catch {}
    }
    func testBothHistoryStoresPurgeAtSevenDaysAndOnReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHistoryStore(url: url, now: 0)
        let memory = InMemoryHistoryStore()
        for store: any HistoryStore in [memory, file] {
            try await store.append(HistoryEntry(segmentID: "old", targetID: "phone", text: "synthetic", createdAt: 1), now: 1)
            try await store.append(HistoryEntry(segmentID: "new", targetID: "phone", text: "fixture", createdAt: 2), now: 2)
            let before = try await store.entries(now: 604_800_000)
            XCTAssertEqual(before.count, 2)
            try await store.purge(now: 604_800_001)
            let after = try await store.entries(now: 604_800_001)
            XCTAssertEqual(after.map(\.segmentID), ["new"])
        }
        let reopened = try FileHistoryStore(url: url, now: 604_800_002)
        let entries = try await reopened.entries(now: 604_800_002)
        XCTAssertTrue(entries.isEmpty)
        let raw = try String(contentsOf: url, encoding: .utf8)
        let envelope = try JSONDecoder().decode(AccountRecordEnvelope<[HistoryEntry]>.self, from: Data(raw.utf8))
        XCTAssertEqual(envelope.accountID, "owner-local"); XCTAssertTrue(envelope.records.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testDictationOnlyDeliversSanitizedTextAfterExposingPinnedTarget() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        try await registry.register(device("phone")); try await registry.register(device("laptop"))
        let history = InMemoryHistoryStore(); let target = TextSpy()
        let pipeline = DictationPipeline(history: history, target: target, registry: registry)
        var picker = TargetPicker(accountID: "test", phoneID: "phone")
        try picker.update(focus("laptop", 1))
        _ = try await pipeline.prepare(segmentID: "s", state: AppState(), picker: picker, now: 1)
        var changed = picker; changed.selection = .device("phone")
        let exposed = await target.events
        XCTAssertEqual(exposed, ["show:laptop"])
        let controls = String(String.UnicodeScalarView((0...0x1f).compactMap(Unicode.Scalar.init)))
            + String(String.UnicodeScalarView((0x7f...0x9f).compactMap(Unicode.Scalar.init))) + "\u{2028}\u{2029}"
        try await pipeline.commit(segmentID: "s", revision: 1, text: "Send Enter 😀" + controls, now: 2)
        let messages = await target.messages
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages[0].target_device_id, "laptop")
        XCTAssertEqual(messages[0].text, "Send Enter 😀")
        let data = try ProtocolCodec.encode(messages[0])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["kind", "account_id", "segment_id", "revision", "state", "target_device_id", "text"])
        XCTAssertEqual(json["kind"] as? String, "dictation_text")
        let saved = await history.entries(now: 2)
        XCTAssertEqual(saved.map(\.text), ["Send Enter 😀"])
        let events = await target.events
        XCTAssertEqual(events, ["show:laptop", "insert:laptop"])
        do { try await pipeline.commit(segmentID: "s", revision: 2, text: "fixture", now: 2); XCTFail() } catch {}
    }
    func testDictationRejectsBrainModeUnpreparedRevokedAndInvalidWire() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        try await registry.register(device("phone"))
        let target = TextSpy(); let history = InMemoryHistoryStore()
        let pipeline = DictationPipeline(history: history, target: target, registry: registry)
        let picker = TargetPicker(accountID: "test", phoneID: "local-phone")
        var state = AppState(); state.setTarget(.device("phone")); state.setMode(.ai_control)
        do { _ = try await pipeline.prepare(segmentID: "s", state: state, picker: picker, now: 0); XCTFail() } catch {}
        do { try await pipeline.commit(segmentID: "s", revision: 0, text: "fixture", now: 0); XCTFail() } catch {}
        state.setMode(.dictation)
        _ = try await pipeline.prepare(segmentID: "s", state: state, picker: picker, now: 0)
        do { try await pipeline.commit(segmentID: "s", revision: -1, text: "fixture", now: 0); XCTFail() } catch {}
        _ = try await pipeline.prepare(segmentID: "revoked", state: state, picker: picker, now: 0)
        try await registry.revoke("phone")
        do { try await pipeline.commit(segmentID: "revoked", revision: 0, text: "fixture", now: 0); XCTFail() } catch {}
        let messages = await target.messages; let entries = await history.entries(now: 0)
        XCTAssertTrue(messages.isEmpty); XCTAssertTrue(entries.isEmpty)
    }
    func testCoreManifestCannotDependOnBrain() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("Brain"))
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("import Brain"))
        }
    }
}

private actor GatedHistory: HistoryStore {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func append(_ entry: HistoryEntry, now: Int64) async {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func entries(now: Int64) -> [HistoryEntry] { [] }
    func purge(now: Int64) {}
}

private actor GatedTarget: DictationTarget {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var inserted = false
    func showTarget(_ device: DeviceInfo) async {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func insert(_ text: DictationText) { inserted = true }
}

extension LogicTests {
    func testRevocationWhileHistoryIsSuspendedPreventsInsertion() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        try await registry.register(device("phone"))
        let history = GatedHistory(); let sink = TextSpy()
        let pipeline = DictationPipeline(history: history, target: sink, registry: registry)
        var state = AppState(); state.setTarget(.device("phone"))
        _ = try await pipeline.prepare(segmentID: "s", state: state, picker: TargetPicker(accountID: "test", phoneID: "local-phone"), now: 0)
        let committing = Task { try await pipeline.commit(segmentID: "s", revision: 1, text: "fixture", now: 0) }
        await history.waitUntilStarted()
        try await registry.revoke("phone")
        await history.release()
        do { try await committing.value; XCTFail("delivered after revocation") } catch {}
        let messages = await sink.messages
        XCTAssertTrue(messages.isEmpty)
    }
    func testCannotCommitUntilTargetPresentationCompletesAndCancelWins() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        try await registry.register(device("phone"))
        let sink = GatedTarget()
        let pipeline = DictationPipeline(history: InMemoryHistoryStore(), target: sink, registry: registry)
        let preparing = Task { try await pipeline.prepare(segmentID: "s", state: AppState(), picker: TargetPicker(accountID: "test", phoneID: "phone"), now: 0) }
        await sink.waitUntilStarted()
        do { try await pipeline.commit(segmentID: "s", revision: 1, text: "fixture", now: 0); XCTFail("committed before presentation") } catch {}
        await pipeline.cancel(segmentID: "s")
        await sink.release()
        do { _ = try await preparing.value; XCTFail("canceled preparation survived") } catch {}
        let inserted = await sink.inserted
        XCTAssertFalse(inserted)
    }
}

extension LogicTests {
    func testReopenCleansCrashOrphanWithoutTouchingAnotherStoresPendingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let pending = directory.appendingPathComponent(".history.json.history-pending")
        let otherPending = directory.appendingPathComponent(".other.json.history-pending")
        try Data("synthetic orphan".utf8).write(to: pending)
        try Data("different store".utf8).write(to: otherPending)
        let store = try FileHistoryStore(url: file, now: 0)
        let entries = try await store.entries(now: 0)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherPending.path))
    }
}

extension LogicTests {
    func testTwoShortTapsLockWithoutOpeningHoldAndSingleTapDoesNothing() {
        var trigger = CaptureTrigger()
        trigger.press(at: 0); trigger.advance(to: 99)
        XCTAssertEqual(trigger.capture, .off)
        trigger.release(at: 100)
        XCTAssertEqual(trigger.capture, .off)
        trigger.press(at: 200); trigger.advance(to: 299)
        XCTAssertEqual(trigger.capture, .off)
        trigger.release(at: 300)
        XCTAssertEqual(trigger.capture, .continuous)
    }
    func testOrdinaryHoldsNeverLockAndHoldBetweenTapsClearsPendingTap() {
        var trigger = CaptureTrigger()
        trigger.press(at: 0); trigger.advance(to: 299)
        XCTAssertEqual(trigger.capture, .off)
        trigger.advance(to: 300); XCTAssertEqual(trigger.capture, .hold)
        trigger.release(at: 400); XCTAssertEqual(trigger.capture, .off)
        trigger.press(at: 450); trigger.advance(to: 750)
        XCTAssertEqual(trigger.capture, .hold)
        trigger.release(at: 850); XCTAssertEqual(trigger.capture, .off)

        trigger.press(at: 1000); trigger.release(at: 1100)
        trigger.press(at: 1150); trigger.advance(to: 1450)
        XCTAssertEqual(trigger.capture, .hold)
        trigger.release(at: 1450)
        trigger.press(at: 1500); trigger.release(at: 1600)
        XCTAssertEqual(trigger.capture, .off)
        trigger.press(at: 1650); trigger.release(at: 1750)
        XCTAssertEqual(trigger.capture, .continuous)
    }
    func testClockSkewAndFuturePeerTimestampsCannotRejectOrPoisonFreshFocus() throws {
        let clock = TestFocusClock(1000)
        var picker = TargetPicker(accountID: "test", phoneID: "phone", clock: clock)
        let devices = [device("phone"), device("laptop"), device("desktop")]
        let now: Int64 = 1000
        try picker.update(focus("laptop", 9_007_199_254_740_991))
        XCTAssertEqual(try picker.resolve(at: now + 1000, devices: devices).device_id, "laptop")
        try picker.update(focus("laptop", 0, focused: false))
        XCTAssertEqual(try picker.resolve(at: now + 1000, devices: devices).device_id, "phone")
        try picker.update(focus("desktop", 0))
        XCTAssertEqual(try picker.resolve(at: now + 1000, devices: devices).device_id, "desktop")
    }
    func testPhoneFallbackAndFixedPhoneDoNotRequireRegistryEnrollment() throws {
        var picker = TargetPicker(accountID: "test", phoneID: "phone")
        XCTAssertEqual(try picker.resolve(at: 0, devices: []).device_id, "phone")
        picker.selection = .device("phone")
        XCTAssertEqual(try picker.resolve(at: 0, devices: []).device_id, "phone")
    }
    func testPeerAssertedDuplicateIDCannotReplaceExistingRegistryEntry() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        let original = device("desktop")
        try await registry.register(original)
        do {
            try await registry.register(device("desktop", role: .agent, capabilities: [.external_send]))
            XCTFail("peer-asserted ID overwrote the enrolled device")
        } catch {}
        let devices = await registry.all()
        XCTAssertEqual(devices, [original])
    }
    func testLineBreaksPreserveWordBoundariesAndEmptySegmentsAreDropped() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        try await registry.register(device("phone"))
        let history = InMemoryHistoryStore(); let sink = TextSpy()
        let pipeline = DictationPipeline(history: history, target: sink, registry: registry)
        let picker = TargetPicker(accountID: "test", phoneID: "phone")
        let inputs = ["  line one\nline two  ", "one\r\n\u{000B}\u{000C}\u{0085}\u{2028}\u{2029}two", "\n", " \r\n\t\u{0000} "]
        for (index, input) in inputs.enumerated() {
            let segment = "line-\(index)"
            _ = try await pipeline.prepare(segmentID: segment, state: AppState(), picker: picker, now: 0)
            try await pipeline.commit(segmentID: segment, revision: 1, text: input, now: 0)
        }
        let messages = await sink.messages; let entries = await history.entries(now: 0)
        XCTAssertEqual(messages.map(\.text), ["line one line two", "one two"])
        XCTAssertEqual(entries.map(\.text), ["line one line two", "one two"])
        for message in messages { _ = try ProtocolCodec.encode(message) }
    }
    func testPipelineCanInsertIntoUnregisteredLocalPhone() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        let history = InMemoryHistoryStore(); let sink = TextSpy()
        let pipeline = DictationPipeline(history: history, target: sink, registry: registry)
        _ = try await pipeline.prepare(segmentID: "local", state: AppState(), picker: TargetPicker(accountID: "test", phoneID: "phone"), now: 0)
        try await pipeline.commit(segmentID: "local", revision: 1, text: "synthetic", now: 0)
        let messages = await sink.messages
        XCTAssertEqual(messages.map(\.target_device_id), ["phone"])
    }
    func testDependentLogicPackagesDeclareIOS26() throws {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for package in [core, core.deletingLastPathComponent().appendingPathComponent("Protocol"), core.deletingLastPathComponent().appendingPathComponent("Pairing")] {
            let manifest = try String(contentsOf: package.appendingPathComponent("Package.swift"), encoding: .utf8)
            XCTAssertTrue(manifest.contains(".iOS(\"26.0\")"), package.lastPathComponent)
        }
    }
}

extension LogicTests {
    func testExplicitRePairRequiresSuccessfulRevocationAndFreshConfirmation() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        try await registry.register(device("desktop"))
        do { try await registry.rePair(device("desktop", role: .both)); XCTFail("active entry replaced without revocation") } catch {}
        try await registry.revoke("desktop")
        do { try await registry.register(device("desktop")); XCTFail("ordinary enrollment bypassed revocation") } catch {}
        try await registry.rePair(device("desktop", role: .both))
        let paired = try await registry.textReceiver("desktop")
        XCTAssertEqual(paired.role, .both)
        do { try await registry.rePair(device("desktop")); XCTFail("re-pair reused") } catch {}

        let failing = RevocationSpy(); await failing.setFailure()
        let incomplete = DeviceRegistry(accountID: "test", revocation: failing)
        try await incomplete.register(device("desktop"))
        do { try await incomplete.revoke("desktop"); XCTFail() } catch {}
        do { try await incomplete.rePair(device("desktop")); XCTFail("failed cleanup allowed re-pair") } catch {}
    }
}

private final class TestFocusClock: FocusClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    func nowMilliseconds() -> Int64 { lock.withLock { value } }
    func set(_ value: Int64) { lock.withLock { self.value = value } }
}

private actor GatedRevocation: DeviceRevocationHandler {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func deleteKey(deviceID: String) async {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func dropRoom(deviceID: String) {}
}

extension LogicTests {
    func testRePairCannotRaceOutstandingCredentialDeletion() async throws {
        let handler = GatedRevocation()
        let registry = DeviceRegistry(accountID: "test", revocation: handler)
        try await registry.register(device("desktop"))
        let revoking = Task { try await registry.revoke("desktop") }
        await handler.waitUntilStarted()
        do { try await registry.rePair(device("desktop")); XCTFail("installed before old-key cleanup finished") } catch {}
        do { try await registry.register(device("desktop")); XCTFail() } catch {}
        await handler.release(); try await revoking.value
        try await registry.rePair(device("desktop"))
        let paired = try await registry.textReceiver("desktop")
        XCTAssertEqual(paired.device_id, "desktop")
    }
    func testReceiptOrderWinsOverPeerClockAndExpiresOnPhoneClock() throws {
        let clock = TestFocusClock(10)
        var picker = TargetPicker(accountID: "test", phoneID: "phone", clock: clock)
        let devices = [device("a"), device("b")]
        try picker.update(focus("a", 9_007_199_254_740_991))
        clock.set(11); try picker.update(focus("b", 0))
        XCTAssertEqual(try picker.resolve(devices: devices).device_id, "b")
        clock.set(60_011)
        XCTAssertEqual(try picker.resolve(devices: devices).device_id, "b")
        clock.set(60_012)
        XCTAssertEqual(try picker.resolve(devices: devices).device_id, "phone")
    }
    func testPipelineUsesMonotonicFocusClockRatherThanHistoryEpochTime() async throws {
        let registry = DeviceRegistry(accountID: "test", revocation: RevocationSpy())
        try await registry.register(device("desktop"))
        let clock = TestFocusClock(10)
        var picker = TargetPicker(accountID: "test", phoneID: "phone", clock: clock)
        try picker.update(focus("desktop", 0))
        let pipeline = DictationPipeline(history: InMemoryHistoryStore(), target: TextSpy(), registry: registry)
        let chosen = try await pipeline.prepare(segmentID: "epoch", state: AppState(), picker: picker, now: 1_800_000_000_000)
        XCTAssertEqual(chosen.device_id, "desktop")
    }
    func testExactly300MillisecondsIsAHoldEvenWithoutTimerCallback() {
        var trigger = CaptureTrigger()
        trigger.press(at: 0); trigger.release(at: 100)
        trigger.press(at: 150); trigger.release(at: 450)
        XCTAssertEqual(trigger.capture, .off)
        trigger.press(at: 500); trigger.advance(to: 799)
        XCTAssertEqual(trigger.capture, .off)
        trigger.release(at: 799)
        XCTAssertEqual(trigger.capture, .off)
    }
}

extension LogicTests {
    func testDictationSanitizesControlScalarsInCRLFAndCombiningClusters() {
        let cases = [("\r\n", ""), ("a\r\nb", "a b"), ("\n\u{0301}", "\u{0301}"),
                     ("a\n\u{0301}b", "a \u{0301}b"), ("a\u{0000}\u{0301}b", "a\u{0301}b")]
        for (input, expected) in cases {
            let clean = DictationPipeline.sanitize(input)
            XCTAssertEqual(Array(clean.unicodeScalars), Array(expected.unicodeScalars))
            XCTAssertFalse(clean.unicodeScalars.contains { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 })
        }
    }
}

final class InstallationAccountTests: XCTestCase {
    func testRejectsSwitchAcrossRelaunch() throws {
        let first = try InstallationAccount.resolve(requested: "synthetic-owner", pinned: nil)
        XCTAssertEqual(try InstallationAccount.resolve(requested: "synthetic-owner", pinned: first), first)
        XCTAssertThrowsError(try InstallationAccount.resolve(requested: "other", pinned: first))
        XCTAssertThrowsError(try InstallationAccount.resolve(requested: nil, pinned: first))
        XCTAssertEqual(try InstallationAccount.resolve(requested: nil, pinned: nil), "owner-local")
    }
}

extension LogicTests {
    func testPinnedHistoryEnvelopeMigratesLegacyAndRejectsMixedAccountsBeforeRetention() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = HistoryEntry(segmentID: "synthetic", targetID: "phone", text: "Invented", createdAt: 1)
        try JSONEncoder().encode([legacy]).write(to: url)
        let store = try FileHistoryStore(url: url, now: 1, accountID: "test")
        let entries = try await store.entries(now: 1)
        XCTAssertEqual(entries.first?.accountID, "test")
        XCTAssertThrowsError(try FileHistoryStore(url: url, now: 1, accountID: "wrong"))
        let wrong = HistoryEntry(segmentID: "wrong", targetID: "phone", text: "Invented", createdAt: 0, accountID: "wrong")
        try JSONEncoder().encode([legacy, wrong]).write(to: url)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try FileHistoryStore(url: url, now: 604_800_001, accountID: "test"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
