// Purpose: G4/G9 synthetic adapter traces; no device calibration claims.
// Inputs: monotonic controls and generated PCM. Verification: portable tests.
import Foundation
import Testing
import Core
import Stt
@testable import AppModel

private func control(_ tick: UInt32, _ event: UInt8, capture: UInt8 = 1, mode: UInt8 = 0) throws -> RemoteInput {
    var data = Data(repeating: 0, count: 14)
    for i in 0..<4 { data[4+i] = UInt8(truncatingIfNeeded: tick >> (i*8)) }
    data[8] = event; data[9] = capture; data[10] = mode; data[11] = event == 1 ? 1 : 0
    return try RemoteInput(data)
}
@Test func identicalPhoneRemoteTimedTracesIncludingBatchDelayAndClockWrap() throws {
    for base: UInt32 in [0, UInt32.max - 150] {
        for trace: [(UInt32, UInt8)] in [
            [(0,1),(299,2)], [(0,1),(300,2)],
            [(0,1),(20,2),(520,1),(540,2)],
            [(0,1),(20,2),(521,1),(540,2)],
            [(0,1),(20,2),(50,1),(350,2),(400,1),(420,2)]
        ] {
            var phone = CaptureTrigger(), remote = RemoteControls()
            _ = remote.accept(try control(base, 0), edge: false)
            for (tick, event) in trace {
                if event == 1 { phone.press(at: Int64(tick)) }
                else { phone.advance(to: Int64(tick)); phone.release(at: Int64(tick)) }
                _ = remote.accept(try control(base &+ tick, event), edge: true)
                #expect(remote.triggerCapture == phone.capture)
            }
        }
    }
}
@Test func reconnectOffAndModeChangesClearPendingTapAndLock() throws {
    var remote = RemoteControls()
    _ = remote.accept(try control(0, 0), edge: false)
    _ = remote.accept(try control(1, 1), edge: true)
    _ = remote.accept(try control(20, 2), edge: true)
    _ = remote.accept(try control(30, 5, mode: 1), edge: true)
    _ = remote.accept(try control(40, 1, mode: 1), edge: true)
    _ = remote.accept(try control(60, 2, mode: 1), edge: true)
    #expect(remote.triggerCapture == .off)
    _ = remote.accept(try control(70, 4, capture: 0, mode: 1), edge: true)
    #expect(remote.triggerCapture == .off)
    remote.reset()
    _ = remote.accept(try control(90, 0), edge: false)
    #expect(remote.triggerCapture == .off)
}

@MainActor private final class Candidate: CaptureSession {
    nonisolated let stream = AsyncStream<CaptureEvent>.makeStream()
    var stopped = false
    func start() throws {}
    func finish() { stream.continuation.finish(); stopped = true }
    func interrupt() { stream.continuation.yield(.interrupted); finish() }
    nonisolated func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    nonisolated func events() -> AsyncStream<CaptureEvent> { stream.stream }
    func pcm(_ level: Int16) throws { stream.continuation.yield(.frame(try AudioFrame(samples: [Int16](repeating: level, count: 3200), timestamp: 0))) }
}
@Test @MainActor func currentUtteranceCompetingAdaptersPinOneSourceAndFailClosedOnLoss() async throws {
    let phone = Candidate(), remote = Candidate()
    let session = UtteranceCaptureSession(candidates: [
        .init(id: "phone", source: phone), .init(id: "remote", source: remote)])
    try session.start()
    try phone.pcm(32767); try remote.pcm(1000)
    var iterator = session.events().makeAsyncIterator()
    guard case .frame(let first) = await iterator.next() else { Issue.record("missing selected frame"); return }
    #expect(first.samples.first == 1000)
    #expect(session.selectedID == "remote")
    remote.stream.continuation.yield(.interrupted)
    #expect(await iterator.next() == .interrupted)
    #expect(await iterator.next() == nil)
    #expect(phone.stopped)
    #expect(session.diagnostics.allSatisfy { $0.proximity == nil })
}
@Test @MainActor func changedDeviceIdentityAndStaleOrLostCandidatesCannotWin() async throws {
    let phone = Candidate(), remote = Candidate()
    var current = true
    let session = UtteranceCaptureSession(candidates: [
        .init(id: "phone", source: phone), .init(id: "old-remote", source: remote, valid: { current })])
    try session.start(); current = false
    try remote.pcm(1000); try phone.pcm(2000)
    var iterator = session.events().makeAsyncIterator()
    guard case .frame(let frame) = await iterator.next() else { Issue.record("missing phone frame"); return }
    #expect(frame.samples.first == 2000); #expect(session.selectedID == "phone")
    session.finish()
    #expect(await iterator.next() == nil)
    // A new session owns fresh meters; prior observations cannot enter it.
    let lost = Candidate()
    let next = UtteranceCaptureSession(candidates: [.init(id: "new-remote", source: lost)])
    try next.start(); lost.stream.continuation.yield(.interrupted)
    var nextEvents = next.events().makeAsyncIterator()
    #expect(await nextEvents.next() == .interrupted)
    #expect(next.selectedID == nil)
}

@Test @MainActor func comparisonDeadlineRejectsSilentAdapterAndPinnedStreamStaleness() async throws {
    let phone = Candidate(), remote = Candidate()
    let session = UtteranceCaptureSession(candidates: [.init(id: "phone", source: phone), .init(id: "silent-remote", source: remote)])
    try session.start()
    // A fresh prefix just before the acquisition deadline can win; a silent peer cannot.
    try await Task.sleep(for: .milliseconds(200))
    try phone.pcm(1000)
    var events = session.events().makeAsyncIterator()
    guard case .frame = await events.next() else { Issue.record("missing valid prefix"); return }
    #expect(session.selectedID == "phone")
    #expect(await events.next() == .interrupted)
    #expect(await events.next() == nil)
}
@Test @MainActor func replayedFrameCannotEnterPinnedUtterance() async throws {
    let phone = Candidate()
    let session = UtteranceCaptureSession(candidates: [.init(id: "phone", source: phone)])
    try session.start(); try phone.pcm(1000)
    var events = session.events().makeAsyncIterator()
    guard case .frame = await events.next() else { Issue.record("missing prefix"); return }
    try phone.pcm(2000) // repeats timestamp zero
    #expect(await events.next() == .interrupted)
    #expect(await events.next() == nil)
}
@Test @MainActor func competingPhoneAudioRemainsProvisionalUntilRemoteHoldQualifies() async throws {
    for accepted in [false, true] {
        let phone = Candidate()
        let comparison = UtteranceCaptureSession(candidates: [.init(id: "phone", source: phone)])
        let gate = QualifiedCaptureSession(source: comparison)
        try gate.start(); try phone.pcm(1000)
        for _ in 0..<100 where comparison.selectedID == nil { try await Task.sleep(for: .milliseconds(1)) }
        #expect(comparison.selectedID == "phone")
        if accepted { gate.qualify(); phone.finish() } else { gate.interrupt() }
        var events: [CaptureEvent] = []
        for await event in gate.events() { events.append(event) }
        if accepted { #expect(events.count == 1); #expect(events.first != .interrupted) }
        else { #expect(events == [.interrupted]) }
    }
}
@Test @MainActor func phoneEntryTimedTapAndHoldTracesHaveNoApprovalSideEffects() async throws {
    for duration: Int64 in [299, 300] {
        let rig = try Rig()
        rig.model.setCapture(.hold)
        rig.model.press(at: 0); rig.model.advanceTrigger(to: duration)
        if duration == 299 { #expect(rig.capture.starts == 0) }
        else { try await rig.until { rig.capture.starts == 1 } }
        rig.model.release(at: duration)
        #expect(rig.execution.permits.isEmpty)
        rig.model.stop()
    }
    let rig = try Rig()
    rig.model.setCapture(.hold)
    for (press, release): (Int64, Int64) in [(0,20),(520,540)] {
        rig.model.press(at: press); rig.model.release(at: release)
    }
    #expect(rig.model.controls.capture == .continuous)
    #expect(rig.execution.permits.isEmpty)
    rig.model.stop()
}

@Test @MainActor func identityChangeAfterSelectionInterruptsWithoutSwitchingAdapters() async throws {
    let phone = Candidate(), remote = Candidate()
    var sameIdentity = true
    let session = UtteranceCaptureSession(candidates: [.init(id: "phone", source: phone),
        .init(id: "remote-enrollment-A", source: remote, valid: { sameIdentity })])
    try session.start(); try phone.pcm(32767); try remote.pcm(1000)
    var events = session.events().makeAsyncIterator()
    guard case .frame = await events.next() else { Issue.record("missing prefix"); return }
    sameIdentity = false
    #expect(await events.next() == .interrupted)
    #expect(session.selectedID == "remote-enrollment-A")
    #expect(session.diagnostics.last?.identityCurrent == false)
    #expect(await events.next() == nil)
}
@Test func modeChangeAfterLockCannotRestoreLockedPresentation() throws {
    var remote = RemoteControls()
    _ = remote.accept(try control(0, 0), edge: false)
    for (tick,event): (UInt32,UInt8) in [(1,1),(20,2),(40,1),(60,2)] {
        _ = remote.accept(try control(tick, event), edge: true)
    }
    #expect(remote.triggerCapture == .continuous)
    #expect(remote.accept(try control(70, 5, mode: 1), edge: true) == [.boundary, .positions(.hold, .ai_control)])
    #expect(remote.triggerCapture == .off)
}

@Test func provisionalAudioHasASampleBoundAsWellAsAFrameBound() throws {
    var buffer = RemoteHoldBuffer(provisional: true)
    let oversized = try AudioFrame(samples: [Int16](repeating: 0, count: 1_920_001), timestamp: 0)
    #expect(throws: (any Error).self) { _ = try buffer.frame(oversized) }
    #expect(buffer.qualify().isEmpty)
}

@Test @MainActor func comparisonNamesTheActualStartedPhoneRoute() async throws {
    let phone = Candidate()
    let session = UtteranceCaptureSession(candidates: [.init(id: "phone", source: phone, name: { "Synthetic Bluetooth headset" })])
    try session.start(); try phone.pcm(1000)
    var events = session.events().makeAsyncIterator()
    _ = await events.next()
    #expect(session.selectedID == "Synthetic Bluetooth headset")
    #expect(session.diagnostics.first?.id == "Synthetic Bluetooth headset")
    session.finish()
}

@Test @MainActor func productionComparisonFactoryPinsActualPhoneRouteIdentity() async throws {
    let phone = Candidate()
    var route = "synthetic-phone"
    let factory = UtteranceCaptureSession.factory(phone: { phone }, remote: nil, remoteName: "none",
        phoneIdentity: { route }, valid: { true }, remoteValid: { false }, didSelect: { _ in })
    let session = try await factory()
    try session.start()
    route = "synthetic-headset"
    try phone.pcm(1000)
    var events = session.events().makeAsyncIterator()
    #expect(await events.next() == .interrupted)
    #expect(await events.next() == nil)
}
