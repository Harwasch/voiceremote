import Foundation
import Testing
import Core
import Stt
import Brain
import Policy
import Router
import VoiceRemoteProtocol
@testable import AppModel

@Test @MainActor func deliberatePTTWithMatchingGrantSelectsWithoutReview() async throws {
    let rig = try Rig(script: [.final("switch to phone")])
    await rig.model.refresh()
    let phone = TargetPicker(accountID: "fixture", phoneID: "phone").phone
    rig.model.grantTargetSelection(device: phone, project: "default")
    rig.model.setMode(.ai_control); rig.model.setCapture(.hold)
    rig.model.press(at: 0); rig.model.advanceTrigger(to: 300)
    try await rig.until { rig.model.isRecording }
    rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500], timestamp: 0)))
    rig.model.release(at: 400)
    try await rig.until { rig.model.listening == .idle }
    #expect(rig.model.controls.target == .device("phone"))
    #expect(rig.model.approval == nil)
    #expect(rig.bio.count == 0)
    #expect(rig.execution.permits.isEmpty)
}

@Test @MainActor func ambientCardAppearsBeforeCaptureEndsAndReviewDoesNotStopCapture() async throws {
    let rig = try Rig(script: [.final("switch to phone")])
    rig.model.setMode(.ai_control); rig.model.setCapture(.continuous)
    try await rig.until { rig.model.isRecording }
    rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [1000], timestamp: 0)))
    rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: Array(repeating: 0, count: 12_800), timestamp: 0.1)))
    try await rig.until { !rig.model.suggestions.isEmpty }
    #expect(rig.model.isRecording)
    #expect(!rig.capture.stopped)
    let card = try #require(rig.model.suggestions.first)
    await rig.model.review(card); await rig.model.approve()
    #expect(rig.model.controls.target == .device("phone"))
    #expect(rig.model.isRecording)
    #expect(!rig.capture.stopped)
    rig.model.stop()
}

@Test @MainActor func pinnedHistoryMigratesLegacyAndRejectsMixedAccountsBeforeDisplayOrSend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history.json")
    let legacy = HistoryEntry(segmentID: "synthetic", targetID: "pc", text: "Invented text", createdAt: 1)
    try JSONEncoder().encode([legacy]).write(to: url)
    let store = try AppHistoryStore(url: url, now: 1, accountID: "fixture")
    #expect(try await store.entries(now: 1).first?.accountID == "fixture")
    #expect(throws: (any Error).self) { try AppHistoryStore(url: url, now: 1, accountID: "wrong") }
    do {
        try await store.saveText(HistoryEntry(segmentID: "other", targetID: "pc", text: "Invented", createdAt: 1, accountID: "wrong"), state: .held, now: 1)
        Issue.record("Wrong-account text saved")
    } catch {}
    let original = try Data(contentsOf: url)
    let mixed = [legacy, HistoryEntry(segmentID: "other", targetID: "pc", text: "Invented", createdAt: 1, accountID: "wrong")]
    try JSONEncoder().encode(mixed).write(to: url)
    let before = try Data(contentsOf: url)
    #expect(throws: (any Error).self) { try AppHistoryStore(url: url, now: 1, accountID: "fixture") }
    #expect(try Data(contentsOf: url) == before)
    #expect(before != original)
}

@Test func offlineRecordEnvelopeMigratesAndRejectsWrongAccountWithoutMutatingSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("offline.json")
    try Data("{}".utf8).write(to: url)
    _ = try RemoteOfflineSync(url: url, accountID: "fixture")
    let before = try Data(contentsOf: url)
    let object = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    #expect(object["accountID"] as? String == "fixture")
    #expect(object["version"] as? Int == 2)
    #expect(throws: (any Error).self) { try RemoteOfflineSync(url: url, accountID: "wrong") }
    #expect(try Data(contentsOf: url) == before)
}

@Test @MainActor func ambiguousRevokedAndWrongScopePTTNeverSelectAutomatically() async throws {
    for scenario in ["revoked", "wrong-project", "ambiguous", "recorded", "wake"] {
        let text = scenario == "ambiguous" ? "don't switch to phone" : scenario == "wake" ? "Assistant switch to phone" : "switch to phone"
        let rig = try Rig(script: [.final(text)])
        await rig.model.refresh()
        let phone = TargetPicker(accountID: "fixture", phoneID: "phone").phone
        rig.model.grantTargetSelection(device: phone, project: scenario == "wrong-project" ? "other" : "default")
        if scenario == "revoked" { rig.model.revokeGrant(try #require(rig.model.grants.first)) }
        rig.model.wakeArmed = true
        rig.model.setMode(.ai_control)
        if scenario == "recorded" || scenario == "wake" { rig.model.setCapture(.continuous) }
        else { rig.model.setCapture(.hold); rig.model.press(at: 0); rig.model.advanceTrigger(to: 300) }
        try await rig.until { rig.model.isRecording }
        rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500], timestamp: 0)))
        rig.model.finishUtterance(); try await rig.until { rig.model.listening == .idle }
        #expect(rig.model.controls.target == .auto)
        #expect(rig.execution.permits.isEmpty)
        #expect(!rig.model.suggestions.isEmpty)
    }
}

@Test @MainActor func correctionInvalidatesApprovedPermitAfterQueueFailureBeforeRetry() async throws {
    var script = "open the synthetic page"
    var deliveries = 0
    let rig = try Rig(scriptProvider: { [.final(script)] }, tool: .openResourceTool(OpenResourceTool(
        account_id: "fixture", device_id: "phone", resource_uri: "https://example.invalid/synthetic")), delivery: { _ in
            deliveries += 1; throw RouterError.persistence
        })
    rig.model.setMode(.ai_control); rig.model.setCapture(.continuous)
    try await rig.until { rig.model.isRecording }
    func slice(_ time: Double) throws {
        rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [1000], timestamp: time)))
        rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: Array(repeating: 0, count: 12_800), timestamp: time + 0.1)))
    }
    try slice(0); try await rig.until { !rig.model.suggestions.isEmpty }
    await rig.model.review(try #require(rig.model.suggestions.first)); await rig.model.approve()
    #expect(rig.model.canRetryQueue)
    #expect(deliveries == 1)
    let request = try #require(rig.model.approval?.id)
    script = "no, do not open it"
    try slice(1)
    try await rig.until { rig.model.approval == nil }
    #expect(rig.gate.state(requestID: request) == .cancelled)
    await rig.model.approve()
    #expect(deliveries == 1)
    #expect(rig.model.isRecording)
    rig.model.stop()
}

@Test @MainActor func sensitivePTTWithTargetGrantStillWaitsForPhoneReviewAndFreshAuthentication() async throws {
    let rig = try Rig(sensitive: true, script: [.final("prepare synthetic content")])
    await rig.model.refresh()
    rig.model.grantTargetSelection(device: TargetPicker(accountID: "fixture", phoneID: "phone").phone, project: "default")
    rig.model.setMode(.ai_control); rig.model.setCapture(.hold)
    rig.model.press(at: 0); rig.model.advanceTrigger(to: 300)
    try await rig.until { rig.model.isRecording }
    rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500], timestamp: 0)))
    rig.model.release(at: 400); try await rig.until { rig.model.listening == .idle }
    #expect(rig.execution.permits.isEmpty); #expect(rig.bio.count == 0)
    await rig.model.review(try #require(rig.model.suggestions.first))
    #expect(rig.model.approval?.preview.risk == .sensitive)
    await rig.model.approve()
    #expect(rig.bio.count == 1); #expect(rig.execution.permits.count == 1)
}

@Test @MainActor func wrongDeviceAndEditedTargetCannotUsePTTGrantWithoutApproval() async throws {
    let rig = try Rig(script: [.final("switch to phone")])
    let pc = DeviceInfo(account_id: "fixture", device_id: "pc", display_name: "Synthetic PC", platform: .linux,
        role: .text_receiver, capabilities: [.receive_text])
    try await rig.registry.register(pc); await rig.model.refresh()
    rig.model.grantTargetSelection(device: TargetPicker(accountID: "fixture", phoneID: "phone").phone, project: "default")
    rig.model.setTarget(.device("pc")); rig.model.setMode(.ai_control); rig.model.setCapture(.hold)
    rig.model.press(at: 0); rig.model.advanceTrigger(to: 300)
    try await rig.until { rig.model.isRecording }
    rig.capture.channel.continuation.yield(.frame(try AudioFrame(samples: [500], timestamp: 0)))
    rig.model.release(at: 400); try await rig.until { rig.model.listening == .idle }
    #expect(rig.model.controls.target == .device("pc"))
    let card = try #require(rig.model.suggestions.first)
    await rig.model.editTarget(card, device: pc)
    await rig.model.review(try #require(rig.model.suggestions.first))
    #expect(rig.model.approval != nil)
    #expect(rig.model.controls.target == .device("pc"))
    #expect(rig.execution.permits.isEmpty)
}
