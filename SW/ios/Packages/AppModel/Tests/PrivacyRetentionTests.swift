import Foundation
import Testing
import Core
import Router
import VoiceRemoteProtocol
@testable import AppModel

@Test func dormantHistoryExpiresOnRelaunchAndPrunesMetadata() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try AppHistoryStore(url: url, now: 1000)
    try await store.saveText(HistoryEntry(segmentID: "fixture", targetID: "phone", text: "Synthetic.", createdAt: 1000), state: .offline, now: 1000)
    let reopened = try AppHistoryStore(url: url, now: 604_801_000)
    #expect(try await reopened.entries(now: 604_801_000).isEmpty)
    #expect(await reopened.deliveryStates().isEmpty)
}

@Test func heldExpiryRequiresDurableExplicitChoice() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try AppHistoryStore(url: url, now: 1000)
    for state in [TextDeliveryState.held, .failed, .unconfirmed] {
        try await store.saveText(HistoryEntry(segmentID: state.rawValue, targetID: "desktop", text: "Synthetic held text.", createdAt: 1000), state: state, now: 1000)
    }
    let expired: Int64 = 604_801_000
    let reopened = try AppHistoryStore(url: url, now: expired)
    #expect(try await reopened.retentionWarnings(now: expired).count == 3)
    #expect(await reopened.deliveryStates()["held"] == .retentionReview)
    try await reopened.resolveRetention(id: "held", keep: true, now: expired)
    try await reopened.resolveRetention(id: "failed", keep: false, now: expired)
    let again = try AppHistoryStore(url: url, now: expired + 1)
    #expect(try await again.retentionWarnings(now: expired + 1).map(\.segmentID) == ["unconfirmed"])
    #expect(try await again.entries(now: expired + 1).count == 2)
    try await again.setDelivery(.delivered, id: "held")
    #expect(try await again.entries(now: expired + 1).count == 2)
    #expect(try await again.retentionWarnings(now: expired + 604_800_000).map(\.segmentID) == ["unconfirmed"])
    #expect(try await again.entries(now: expired + 604_800_000).count == 1)
}

@Test func legacyHistoryMigrationKeepsHeldButExpiresOrdinaryText() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let entry = HistoryEntry(segmentID: "fixture", targetID: "phone", text: "Synthetic legacy text.", createdAt: 1000)
    try JSONEncoder().encode([entry]).write(to: url)
    let reopened = try AppHistoryStore(url: url, now: 604_801_000)
    #expect(try await reopened.entries(now: 604_801_000).isEmpty)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(entry.text))
}

private final class PrivacyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_000_000
    func read() -> Int64 { lock.withLock { value } }
    func advance() { lock.withLock { value += 604_800_000 } }
    func reset() { lock.withLock { value = 1_000_000 } }
}

@Test @MainActor func taskPayloadExpiryPreservesReplayTombstonesAcrossRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("tasks.json"), clock = PrivacyClock()
    var queue: TaskRouter?
    var devices: [DeviceInfo] = []
    let rig = try Rig(tool: .openResourceTool(.init(account_id: "fixture", device_id: "pc", resource_uri: "https://example.invalid/private-fixture")), delivery: { permit in
        try RegisteredRouting.enqueue(permit, devices: devices, router: queue!)
        return queue!.snapshot()
    })
    try await rig.registry.register(DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Synthetic", platform: .linux, role: .both, capabilities: [.receive_text, .open_resource]))
    devices = await rig.registry.all()
    await rig.model.refresh()
    var store: RetainedTaskStore? = try RetainedTaskStore(url: url, accountID: "fixture", now: { clock.read() })
    queue = try TaskRouter(store: store!, policy: rig.gate)
    try await rig.record(mode: .ai_control)
    await rig.model.review(try #require(rig.model.suggestions.first)); await rig.model.approve()
    let task = try #require(queue?.snapshot().first)
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("private-fixture"))
    clock.advance(); try store!.maintain()
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("private-fixture"))
    queue = nil; store = nil
    let reopened = try RetainedTaskStore(url: url, accountID: "fixture", now: { clock.read() })
    #expect(try reopened.load().isEmpty)
    clock.reset() // The old command is live again; its tombstone must still reject replay.
    #expect(throws: (any Error).self) { try reopened.save([task], replacing: []) }
    #expect(!String(decoding: try Data(contentsOf: url.appendingPathExtension("retired")), as: UTF8.self).contains("private-fixture"))
}

@Test func migratedConsentDefaultsOffAndWithdrawalSurvivesRelaunch() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{}".utf8).write(to: url)
    let store = SettingsStore(url: url)
    var settings = try #require(try store.load())
    #expect(!settings.cloudConsent)
    settings.cloudConsent = true; try store.save(settings)
    settings.cloudConsent = false; try store.save(settings)
    #expect(try SettingsStore(url: url).load()?.cloudConsent == false)
}

@Test @MainActor func dormantBenchmarkExportExpiresButExplicitlyKeptAudioRemains() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let export = root.appendingPathComponent("bench-synthetic.json"), kept = root.appendingPathComponent("synthetic.pcm.kept")
    try Data("{}".utf8).write(to: export); try Data([0, 0]).write(to: kept)
    let stale = Date().addingTimeInterval(-604_801)
    try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: export.path)
    _ = try BenchmarkRecorder(prompts: [], directory: root)
    #expect(!FileManager.default.fileExists(atPath: export.path))
    #expect(FileManager.default.fileExists(atPath: kept.path))
}
