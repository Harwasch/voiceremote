import Foundation
import Testing
import Core
import VoiceRemoteProtocol
@testable import AppModel

@Test func heldTextSurvivesRestartWithoutAutomaticDelivery() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try AppHistoryStore(url: url, now: 1000, accountID: "fixture")
    let entry = HistoryEntry(segmentID: "synthetic", targetID: "desktop", text: "Invented fixture.", createdAt: 1000)
    try await store.saveText(entry, state: .held, now: 1000)
    let reopened = try AppHistoryStore(url: url, now: 1001, accountID: "fixture")
    #expect(try await reopened.entries(now: 1001) == [try RecordAccount.bind(entry, to: "fixture")])
    #expect(await reopened.deliveryStates()["synthetic"] == .held)
}

private actor HeldTarget: DictationAvailability, DeviceRevocationHandler {
    var neverClaimed = false
    func certifyNeverClaimed() { neverClaimed = true }
    func reconcile(segmentID: String, deviceID: String) throws -> DictationOutcome {
        guard neverClaimed else { throw DictationDeliveryError.unconfirmed }
        return DictationOutcome(account_id: "fixture", segment_id: segmentID, target_device_id: deviceID, outcome: .unavailable)
    }
    var online = false
    var epoch = UUID()
    var outcome: DictationDeliveryError?
    var inserted: [DictationText] = []
    func setOnline(_ value: Bool, outcome: DictationDeliveryError? = nil) { if value != online { epoch = UUID() }; online = value; self.outcome = outcome }
    func isReachable(_ deviceID: String) -> Bool { online }
    func deliveryEpoch(_ deviceID: String) -> UUID? { online ? epoch : nil }
    func showTarget(_ device: DeviceInfo) throws { if !online { throw DictationDeliveryError.unreachable } }
    func insert(_ text: DictationText) throws {
        if !online { throw DictationDeliveryError.unreachable }
        inserted.append(text)
        if let outcome { throw outcome }
    }
    func deleteKey(deviceID: String) {}
    func dropRoom(deviceID: String) {}
}
@Test func lostDesktopHoldsAcrossRestartAndSendsOnlyOnTap() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let target = HeldTarget(), registry = DeviceRegistry(accountID: "fixture", revocation: target)
    let desktop = DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic PC", platform: .linux, role: .text_receiver, capabilities: [.receive_text])
    try await registry.register(desktop)
    var state = AppState(); state.setTarget(.device("desktop"))
    let store = try AppHistoryStore(url: url, now: 1000, accountID: "fixture")
    let first = HeldDictationPipeline(history: store, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
    _ = try await first.prepare(segmentID: "held-synthetic", state: state, picker: TargetPicker(accountID: "fixture", phoneID: "phone"), now: 1000)
    try await first.commit(segmentID: "held-synthetic", revision: 0, text: "Invented\ntext.", now: 1000)
    #expect(await store.deliveryStates()["held-synthetic"] == .held)
    let reopened = try AppHistoryStore(url: url, now: 700_000_000, accountID: "fixture")
    #expect(try await reopened.entries(now: 700_000_000).count == 1) // never age out undelivered text
    await target.setOnline(true)
    let second = HeldDictationPipeline(history: reopened, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
    #expect(await target.inserted.isEmpty)
    await #expect(throws: DictationDeliveryError.retentionChoiceRequired) { try await second.sendHeld(id: "held-synthetic", now: 700_000_000) }
    try await reopened.resolveRetention(id: "held-synthetic", keep: true, now: 700_000_000)
    try await second.sendHeld(id: "held-synthetic", now: 700_000_000)
    #expect(await target.inserted.count == 1)
    #expect(await target.inserted.first?.text == "Invented text.")
    #expect(await reopened.deliveryStates()["held-synthetic"] == .delivered)
}
@Test func failedOrAmbiguousInsertionKeepsHonestDurableState() async throws {
    for outcome in [DictationDeliveryError.failed, .unconfirmed] {
        let target = HeldTarget(); await target.setOnline(true, outcome: outcome)
        let registry = DeviceRegistry(accountID: "fixture", revocation: target)
        let desktop = DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic PC", platform: .linux, role: .text_receiver, capabilities: [.receive_text])
        try await registry.register(desktop)
        let history = try AppHistoryStore(now: 1000, accountID: "fixture")
        let pipeline = HeldDictationPipeline(history: history, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
        var state = AppState(); state.setTarget(.device("desktop"))
        _ = try await pipeline.prepare(segmentID: "fixture", state: state, picker: TargetPicker(accountID: "fixture", phoneID: "phone"), now: 1000)
        try await pipeline.commit(segmentID: "fixture", revision: 0, text: "Invented.", now: 1000)
        #expect(await history.deliveryStates()["fixture"] == (outcome == .failed ? .failed : .unconfirmed))
        #expect(try await history.entries(now: 1000).count == 1)
    }
}

@Test func returningDesktopCannotAutoInsertAnUtteranceFromAnEarlierLink() async throws {
    for initiallyOnline in [true, false] {
        let target = HeldTarget(); await target.setOnline(initiallyOnline)
        let registry = DeviceRegistry(accountID: "fixture", revocation: target)
        try await registry.register(DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic PC", platform: .linux, role: .text_receiver, capabilities: [.receive_text]))
        let history = try AppHistoryStore(now: 1000, accountID: "fixture")
        let pipeline = HeldDictationPipeline(history: history, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
        var state = AppState(); state.setTarget(.device("desktop"))
        _ = try await pipeline.prepare(segmentID: "fixture", state: state, picker: TargetPicker(accountID: "fixture", phoneID: "phone"), now: 1000)
        await target.setOnline(false); await target.setOnline(true)
        try await pipeline.commit(segmentID: "fixture", revision: 0, text: "Invented fixture.", now: 1000)
        #expect(await target.inserted.isEmpty)
        #expect(await history.deliveryStates()["fixture"] == .held)
        try await pipeline.sendHeld(id: "fixture", now: 1000)
        #expect(await target.inserted.count == 1)
    }
}

private actor BlockingTapTarget: DictationTarget, DeviceRevocationHandler {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    var insertions = 0
    func showTarget(_ device: DeviceInfo) async {
        started.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator(); _ = await iterator.next()
    }
    func allow() { release.continuation.yield(()) }
    func insert(_ text: DictationText) { insertions += 1 }
    func deleteKey(deviceID: String) {}
    func dropRoom(deviceID: String) {}
}
@Test func repeatedSendTapsCannotRaceIntoDuplicateInsertion() async throws {
    let target = BlockingTapTarget(), registry = DeviceRegistry(accountID: "fixture", revocation: target)
    try await registry.register(DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic PC", platform: .linux, role: .text_receiver, capabilities: [.receive_text]))
    let history = try AppHistoryStore(now: 1000, accountID: "fixture")
    try await history.saveText(HistoryEntry(segmentID: "held", targetID: "desktop", text: "Invented.", createdAt: 1000), state: .held, now: 1000)
    let pipeline = HeldDictationPipeline(history: history, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
    let first = Task { try await pipeline.sendHeld(id: "held", now: 1000) }
    var started = target.started.stream.makeAsyncIterator(); _ = await started.next()
    await #expect(throws: (any Error).self) { try await pipeline.sendHeld(id: "held", now: 1000) }
    await target.allow(); try await first.value
    #expect(await target.insertions == 1)
}

@Test func oversizedDictationIsSplitAndDurableBeforeAnyDelivery() async throws {
    let target = HeldTarget(), registry = DeviceRegistry(accountID: "fixture", revocation: target)
    try await registry.register(DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic PC", platform: .linux, role: .text_receiver, capabilities: [.receive_text]))
    let store = try AppHistoryStore(now: 1000, accountID: "fixture")
    let pipeline = HeldDictationPipeline(history: store, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
    var state = AppState(); state.setTarget(.device("desktop"))
    let text = String(repeating: "🦀e\u{301}", count: 12000), id = UUID().uuidString
    _ = try await pipeline.prepare(segmentID: id, state: state, picker: TargetPicker(accountID: "fixture", phoneID: "phone"), now: 1000)
    try? await pipeline.commit(segmentID: id, revision: 0, text: text, now: 1000)
    let entries = try await store.entries(now: 1000)
    #expect(Data(entries.map(\.text).joined().utf8) == Data(text.utf8))
    #expect(entries.count > 1)
    #expect(entries.allSatisfy { $0.text.unicodeScalars.count <= 16384 && $0.text.utf8.count <= 16384 })
    #expect(await target.inserted.isEmpty)
}

@Test func unconfirmedHistoryTapReconcilesBeforeAnyTextResend() async throws {
    let target = HeldTarget(); await target.setOnline(true, outcome: .unconfirmed)
    let registry = DeviceRegistry(accountID: "fixture", revocation: target)
    let desktop = DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic PC", platform: .linux, role: .text_receiver, capabilities: [.receive_text])
    try await registry.register(desktop)
    let history = try AppHistoryStore(now: 1000, accountID: "fixture")
    let pipeline = HeldDictationPipeline(history: history, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
    var state = AppState(); state.setTarget(.device("desktop"))
    _ = try await pipeline.prepare(segmentID: "uncertain-tap", state: state, picker: TargetPicker(accountID: "fixture", phoneID: "phone"), now: 1000)
    try await pipeline.commit(segmentID: "uncertain-tap", revision: 0, text: "Synthetic.", now: 1000)
    #expect(await target.inserted.count == 1)
    await #expect(throws: DictationDeliveryError.unconfirmed) { try await pipeline.sendHeld(id: "uncertain-tap", now: 1001) }
    #expect(await target.inserted.count == 1)
    #expect(await history.deliveryStates()["uncertain-tap"] == .unconfirmed)
}

@Test func unconfirmedTapResendsSameIdentityOnlyAfterNeverClaimedAnswer() async throws {
    let target = HeldTarget(); await target.setOnline(true); await target.certifyNeverClaimed()
    let registry = DeviceRegistry(accountID: "fixture", revocation: target)
    try await registry.register(DeviceInfo(account_id: "fixture", device_id: "desktop", display_name: "Synthetic", platform: .linux, role: .text_receiver, capabilities: [.receive_text]))
    let history = try AppHistoryStore(now: 1000, accountID: "fixture")
    try await history.saveText(HistoryEntry(segmentID: "never-arrived", targetID: "desktop", text: "Synthetic.", createdAt: 1000), state: .unconfirmed, now: 1000)
    let pipeline = HeldDictationPipeline(history: history, target: target, registry: registry, accountID: "fixture", phoneID: "phone")
    try await pipeline.sendHeld(id: "never-arrived", now: 1000)
    #expect(await target.inserted.map(\.segment_id) == ["never-arrived"])
    #expect(await history.deliveryStates()["never-arrived"] == .delivered)
    await #expect(throws: (any Error).self) { try await pipeline.sendHeld(id: "never-arrived", now: 1000) }
    #expect(await target.inserted.count == 1)
}
