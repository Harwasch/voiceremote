import Foundation
import Testing
import Core
import Stt
import VoiceRemoteProtocol
@testable import AppModel

private func info(_ minor: UInt8 = 1, capabilities: UInt16 = 0xbf) throws -> RemoteInfo {
    try RemoteInfo(Data([1, minor, 255, 255, 0, 1, 2, 0]) + OfflineWire.le(UInt64(capabilities), 2) + Data([1, 1, 240, 0, 24, 1, 0, 2, 0, 0]))
}
private func progress() throws -> OfflineProgress {
    var data = Data(repeating: 0, count: 46); data[2] = 1; data[34] = 7
    return try OfflineProgress(data, minor: 1)
}
private actor OfflineRemote {
    let audio: Data
    let metadata: OfflineMetadata
    var offsets: [Int] = []
    var deletes = 0
    var failAt: Int?
    var loseDelete = false
    var deleted = false
    init(frames: Int = 160, failAt: Int? = nil) throws {
        audio = Data((0..<frames).flatMap { _ in [UInt8(3), 0, 0, 1, 2] })
        var raw = OfflineWire.le(1, 8) + OfflineWire.le(7, 4) + OfflineWire.le(1000, 8) + OfflineWire.le(0, 8)
        raw += Data([1, 1]) // Even AI-mode offline audio goes only to history.
        raw += OfflineWire.le(UInt64(audio.count), 4) + OfflineWire.le(UInt64(frames), 4) + OfflineWire.le(UInt64(OfflineWire.crc32(audio)), 4)
        metadata = try OfflineMetadata(raw); self.failAt = failAt
    }
    func allowRetry(loseDelete: Bool = false) { failAt = nil; self.loseDelete = loseDelete }
    func send(_ request: Data) throws -> Data {
        switch request[0] {
        case 1: #expect(request.count == 21); return Data([1, 0])
        case 2:
            #expect(request.count == 9)
            return deleted || OfflineWire.integer(request, 1, 8) >= 1 ? Data([2, 1]) : Data([2, 0]) + metadata.raw
        case 3:
            let offset = Int(OfflineWire.integer(request, 9, 4)), count = Int(OfflineWire.integer(request, 13, 2))
            offsets.append(offset)
            if let failAt, offset >= failAt { throw RemoteContractError.loss }
            return Data([3, 0]) + OfflineWire.le(1, 8) + OfflineWire.le(UInt64(offset), 4) + OfflineWire.le(UInt64(count), 2) + audio.subdata(in: offset..<offset+count)
        case 4:
            #expect(request.count == 17)
            #expect(OfflineWire.integer(request, 9, 4) == UInt64(audio.count))
            #expect(OfflineWire.integer(request, 13, 4) == UInt64(metadata.crc))
            deletes += 1; deleted = true
            if loseDelete { loseDelete = false; throw RemoteContractError.loss }
            return Data([4, 0])
        default: throw RemoteContractError.malformed
        }
    }
}
private actor OfflineResult {
    var stt = 0
    var text: [String: String] = [:]
    var fail = false
    func setFail(_ value: Bool) { fail = value }
    func transcribe(_ packets: [Data]) throws -> String {
        stt += 1
        if fail { throw SttFailure.unavailable }
        #expect(!packets.isEmpty); return "Invented offline fixture."
    }
    func save(_ id: String, _ value: String) { text[id] = value }
}
@Test func offlineFetchResumesAfterRestartAndDeletesOnlyAfterSTTAndHistory() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let remote = try OfflineRemote(failAt: 496), result = OfflineResult()
    func run(_ sync: RemoteOfflineSync) async throws {
        try await sync.synchronize(remote: "enrolled-synthetic", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
            request: { try await remote.send($0) }, transcribe: { try await result.transcribe($0) }, saveText: { await result.save($0, $1) })
    }
    let first = try RemoteOfflineSync(url: url)
    await #expect(throws: (any Error).self) { try await run(first) }
    #expect(await first.pendingAudioBytes() == 496)
    #expect(await remote.deletes == 0); #expect(await result.stt == 0)
    await remote.allowRetry(loseDelete: true)
    let second = try RemoteOfflineSync(url: url)
    await #expect(throws: (any Error).self) { try await run(second) }
    #expect(await remote.offsets == [0, 496, 496])
    #expect(await second.pendingAudioBytes() == 0)
    #expect(await result.stt == 1); #expect(await result.text.count == 1)
    let third = try RemoteOfflineSync(url: url)
    try await run(third)
    #expect(await remote.deletes == 2); #expect(await result.stt == 1)
    #expect(await result.text.count == 1)
}
@Test func failedOfflineTranscriptionRetainsSourceAndNeverDeletes() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let remote = try OfflineRemote(frames: 15), result = OfflineResult()
    await result.setFail(true)
    let sync = try RemoteOfflineSync(url: url)
    await #expect(throws: (any Error).self) {
        try await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
            request: { try await remote.send($0) }, transcribe: { try await result.transcribe($0) }, saveText: { await result.save($0, $1) })
    }
    #expect(await remote.deletes == 0); #expect(await sync.pendingAudioBytes() == 75)
}
@Test func shortOfflineRecordingIsDurablyDiscardedWithoutSTT() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let remote = try OfflineRemote(frames: 14), result = OfflineResult(), sync = try RemoteOfflineSync(url: url)
    try await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
        request: { try await remote.send($0) }, transcribe: { try await result.transcribe($0) }, saveText: { await result.save($0, $1) })
    #expect(await remote.deletes == 1); #expect(await result.stt == 0); #expect(await result.text.isEmpty)
}
@Test @MainActor func lateOfflineTextNeverInsertsOrInvokesBrain() async throws {
    let rig = try Rig()
    rig.model.setMode(.ai_control)
    try await rig.model.saveOfflineText(id: "offline-synthetic-1", text: "Invented late text.")
    #expect(rig.model.deliveryStates["offline-synthetic-1"] == .offline)
    #expect(rig.model.history.first?.text == "Invented late text.")
    #expect(await rig.target.inserted.isEmpty); #expect(await rig.brain.calls == 0)
}
@Test func remoteVersionCompatibilityAndCapabilityGates() throws {
    #expect(try !info(0, capabilities: 0x3f).supportsOfflineSync)
    #expect(try info().supportsOfflineSync)
    #expect(try info(2, capabilities: 0x81bf).supportsOfflineSync)
    #expect(throws: (any Error).self) { try info(1, capabilities: 0x81bf) }
    var input = Data(repeating: 0, count: 14); input[12] = 0x88
    #expect(try RemoteInput(input, minor: 2).status == 8)
    #expect(throws: (any Error).self) { try RemoteInput(input, minor: 1) }
    var major = Data([2, 1, 255, 255, 0, 1, 2, 0, 0xbf, 0, 1, 1, 240, 0, 24, 1, 0, 2, 0, 0])
    #expect(throws: (any Error).self) { try RemoteInfo(major) }
    major[0] = 1; #expect(try RemoteInfo(major).supportsOfflineSync)
}
@Test func offlineEnvelopeAndCRCRejectCorruption() throws {
    let payload = Data([2, 0]) + Data(repeating: 1, count: 42)
    let fragments = try OfflineWire.fragments(payload, transaction: 3, budget: 20)
    var assembly = OfflineAssembly()
    for part in fragments.dropLast() { #expect(try assembly.accept(part, expected: 3) == nil) }
    #expect(try assembly.accept(fragments.last!, expected: 3)?.1 == payload)
    #expect(OfflineWire.crc32(Data("123456789".utf8)) == 0xcbf43926)
    var gap = OfflineAssembly()
    #expect(throws: (any Error).self) { try gap.accept(fragments[1], expected: 3) }
}

@Test func offlineCorruptionAndFailedHistoryNeverConfirmDeletion() async throws {
    for corrupt in [true, false] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let remote = try OfflineRemote(frames: 15), result = OfflineResult(), sync = try RemoteOfflineSync(url: url)
        await #expect(throws: (any Error).self) {
            try await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
                request: { request in
                    var data = try await remote.send(request)
                    if corrupt, request[0] == 3 { data[data.count - 1] ^= 1 }
                    return data
                }, transcribe: { try await result.transcribe($0) }, saveText: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        }
        #expect(await remote.deletes == 0)
        #expect(await result.stt == (corrupt ? 0 : 1))
        if !corrupt {
            // STT succeeded and source audio was deleted, but durable text still
            // retries the failed history transaction without another STT job.
            let reopened = try RemoteOfflineSync(url: url)
            try await reopened.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
                request: { try await remote.send($0) }, transcribe: { try await result.transcribe($0) }, saveText: { await result.save($0, $1) })
            #expect(await result.stt == 1); #expect(await remote.deletes == 1)
            #expect(await reopened.pendingAudioBytes() == 0)
        }
    }
}
@Test func offlineSyncRequiresEnrollmentAndAdvertisedCapability() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let sync = try RemoteOfflineSync(url: url)
    for enrolled in [false, true] {
        await #expect(throws: (any Error).self) {
            try await sync.synchronize(remote: "fixture", info: info(1, capabilities: enrolled ? 0x3f : 0xbf), enrolled: enrolled,
                progress: progress(), utcMilliseconds: 1000,
                request: { _ in Issue.record("Unenrolled/capability-disabled sync emitted bytes"); throw RemoteContractError.notReady },
                transcribe: { _ in Issue.record("Unexpected STT"); return "" }, saveText: { _, _ in Issue.record("Unexpected history") })
        }
    }
}

@Test func offlineHistoryKeepsCaptureClockSeparateFromReceiptTime() async throws {
    let remote = try OfflineRemote(frames: 15)
    let metadata = await remote.metadata
    let origin = OfflineTextOrigin(metadata)
    #expect(origin.estimatedUTC == 0); #expect(origin.bootID == 7); #expect(origin.startTick == 1000)
    #expect(origin.label.contains("Capture time unknown"))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try AppHistoryStore(url: url, now: 2000)
    try await store.saveText(HistoryEntry(segmentID: "offline-fixture", targetID: "phone", text: "Invented.", createdAt: 2000), state: .offline, now: 2000, origin: origin)
    let reopened = try AppHistoryStore(url: url, now: 2001)
    #expect(await reopened.offlineOrigins()["offline-fixture"] == origin)
}
@Test func olderSettingsDecodeWithDeploymentModelAndVersionDefaults() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"cloudConsent\":false,\"relayURL\":\"https://relay.invalid\"}".utf8))
    #expect(settings.cloudModel == "claude-opus-5-5"); #expect(settings.cloudAPIVersion == "2026-10-21")
    #expect(!settings.cloudConsent)
}

@Test func crashedOrFailedSTTIsNotAutomaticallySubmittedAgainOnReconnect() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let remote = try OfflineRemote(frames: 15), result = OfflineResult()
    await result.setFail(true)
    func run(_ sync: RemoteOfflineSync) async throws {
        try await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
            request: { try await remote.send($0) }, transcribe: { try await result.transcribe($0) }, saveText: { await result.save($0, $1) })
    }
    await #expect(throws: (any Error).self) { try await run(RemoteOfflineSync(url: url)) }
    #expect(await result.stt == 1)
    await result.setFail(false)
    let reopened = try RemoteOfflineSync(url: url)
    await #expect(throws: (any Error).self) { try await run(reopened) }
    #expect(await result.stt == 1); #expect(await remote.deletes == 0)
    try await reopened.retryFailedTranscriptions(remote: "fixture") // deliberate Retry tap
    try await run(reopened)
    #expect(await result.stt == 2); #expect(await remote.deletes == 1)
    #expect(await result.text.count == 1)
}

private actor ReviewedOfflineRemote {
    let firstOversized: Bool
    let audio = Data((0..<15).flatMap { _ in [UInt8(3), 0, 0, 1, 2] })
    var deleted = Set<UInt64>()
    init(oversized: Bool) { firstOversized = oversized }
    func metadata(_ id: UInt64) -> Data {
        let size = id == 1 && firstOversized ? 64 * 1024 * 1024 + 1 : audio.count
        var raw = OfflineWire.le(id, 8) + OfflineWire.le(7, 4) + OfflineWire.le(1000, 8) + OfflineWire.le(0, 8)
        raw += Data([0, 1]) + OfflineWire.le(UInt64(size), 4) + OfflineWire.le(15, 4) + OfflineWire.le(UInt64(OfflineWire.crc32(audio)), 4)
        return raw
    }
    func send(_ request: Data) throws -> Data {
        let id = OfflineWire.integer(request, 1, 8)
        switch request[0] {
        case 1: return Data([1, 0])
        case 2:
            guard let next = [UInt64(1), 2].first(where: { $0 > id && !deleted.contains($0) }) else { return Data([2, 1]) }
            return Data([2, 0]) + metadata(next)
        case 3:
            let offset = Int(OfflineWire.integer(request, 9, 4)), count = Int(OfflineWire.integer(request, 13, 2))
            return Data([3, 0]) + OfflineWire.le(id, 8) + OfflineWire.le(UInt64(offset), 4) + OfflineWire.le(UInt64(count), 2) + audio.subdata(in: offset..<offset+count)
        case 4: deleted.insert(id); return Data([4, 0])
        default: throw RemoteContractError.malformed
        }
    }
}
private actor OfflineAttemptCounter { var value = 0; func next() -> Int { value += 1; return value } }
@Test func silentOrOversizedFirstRecordDoesNotStarveLaterRecordings() async throws {
    for oversized in [false, true] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("audio")) }
        let remote = ReviewedOfflineRemote(oversized: oversized), result = OfflineResult(), sync = try RemoteOfflineSync(url: url), calls = OfflineAttemptCounter()
        try? await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
            request: { try await remote.send($0) }, transcribe: { _ in
                let n = await calls.next(); return !oversized && n == 1 ? "" : "Invented later fixture."
            }, saveText: { await result.save($0, $1) })
        #expect(await result.text.count == 1)
        #expect(await remote.deleted == [2])
    }
}
@Test func partialAudioIsNotRewrittenIntoTheMetadataJournal() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("audio")) }
    let remote = try OfflineRemote(frames: 2000, failAt: 3968), sync = try RemoteOfflineSync(url: url)
    try? await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
        request: { try await remote.send($0) }, transcribe: { _ in "Invented." }, saveText: { _, _ in })
    #expect(await sync.pendingAudioBytes() == 3968)
    #expect(try Data(contentsOf: url).count < 2000)
}

@Test func explicitDiscardPersistsDispositionBeforeRemoteDeletion() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("audio")) }
    let remote = ReviewedOfflineRemote(oversized: false), sync = try RemoteOfflineSync(url: url), calls = OfflineAttemptCounter()
    try? await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
        request: { try await remote.send($0) }, transcribe: { _ in await calls.next() == 1 ? "" : "Invented later." }, saveText: { _, _ in })
    let issues = await sync.issues(remote: "fixture")
    #expect(issues.count == 1); #expect(issues.first?.recordingID == 1)
    #expect(await remote.deleted == [2])
    try await sync.discard(id: RemoteOfflineSync.historyID(remote: "fixture", recording: 1), remote: "fixture")
    #expect(await sync.pendingAudioBytes() == 0)
    #expect(await remote.deleted == [2]) // Discard tap journals before C4.
    let reopened = try RemoteOfflineSync(url: url)
    try await reopened.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000, allowAudioFetch: false,
        request: { request in #expect(request[0] != 3); return try await remote.send(request) }, transcribe: { _ in Issue.record("Discarded audio submitted to STT"); return "" }, saveText: { _, _ in })
    #expect(await remote.deleted == [1, 2])
}
private actor YieldingSTT {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    func transcribe() async throws -> String {
        started.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator(); _ = await iterator.next()
        try Task.checkCancellation(); return "Invented."
    }
}
@Test func livePTTYieldResumesSTTWithoutManualRetryOrBlockingLaterPass() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("audio")) }
    let remote = try OfflineRemote(frames: 15), sync = try RemoteOfflineSync(url: url), gate = YieldingSTT(), interruption = OfflineSyncInterruption()
    let job = Task {
        try await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000, interruption: interruption,
            request: { try await remote.send($0) }, transcribe: { _ in try await gate.transcribe() }, saveText: { _, _ in })
    }
    var started = gate.started.stream.makeAsyncIterator(); _ = await started.next()
    interruption.yieldToLiveCapture(); job.cancel()
    _ = await job.result
    #expect(await remote.deletes == 0); #expect(await sync.pendingAudioBytes() == 75)
    let reopened = try RemoteOfflineSync(url: url)
    try await reopened.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
        request: { try await remote.send($0) }, transcribe: { _ in "Invented resumed fixture." }, saveText: { _, _ in })
    #expect(await remote.deletes == 1)
}
@Test func oneMiBAudioWritesStayLinearAndSourceIsRemovedAfterSTT() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("audio")) }
    let remote = try OfflineRemote(frames: 210000), sync = try RemoteOfflineSync(url: url)
    try await sync.synchronize(remote: "fixture", info: info(), enrolled: true, progress: progress(), utcMilliseconds: 1000,
        request: { try await remote.send($0) }, transcribe: { _ in "Invented fixture." }, saveText: { _, _ in })
    #expect(await sync.audioBytesWritten == 1_050_000)
    #expect(await sync.pendingAudioBytes() == 0)
    #expect(try Data(contentsOf: url).count < 2000)
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathExtension("audio").path).isEmpty)
}
