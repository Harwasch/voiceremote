import Foundation
import Testing
import Stt
@testable import AppModel

private func bytes(_ hex: String) -> Data { Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! }) }
@Test func reconnectRequestsSnapshotWithoutWaitingForInitialNotification() throws {
    var tracker = RemoteInputTracker()
    let first = tracker.stateForWrite(RemotePhoneState())
    #expect(first.requestSnapshot)
    #expect(!first.arm)
    #expect(try first.fragments(transaction: 1, budget: 20).first?[6] == 1)
    #expect(!tracker.synchronized)
    // A retry still requests recovery until an actual Input snapshot arrives.
    #expect(tracker.stateForWrite(RemotePhoneState()).requestSnapshot)
    #expect(try !tracker.accept(RemoteInput(bytes("2a 00 00 00 e8 03 00 00 00 01 01 00 00 00"))))
    #expect(!tracker.stateForWrite(RemotePhoneState()).requestSnapshot)
    var explicit = RemotePhoneState(); explicit.requestSnapshot = true
    #expect(tracker.stateForWrite(explicit).requestSnapshot)
    tracker.reset()
    // Even if subscription happened to deliver the initial snapshot, the first
    // state write after reconnect explicitly requests a fresh one.
    _ = try tracker.accept(RemoteInput(bytes("00 00 00 00 e8 03 00 00 00 01 01 00 00 00")))
    #expect(tracker.stateForWrite(RemotePhoneState()).requestSnapshot)
    #expect(!tracker.stateForWrite(RemotePhoneState()).requestSnapshot)
}
@Test func draftInfoAndSmallMTUAudioVectors() throws {
    let info = try RemoteInfo(bytes("01 00 ff ff 00 01 02 00 3f 00 01 01 f0 00 18 01 00 02 00 00"))
    #expect(info.maxPacket == 512); #expect(!info.hardwareMicCut)
    var assembler = RemoteAudioAssembler(maximum: info.maxPacket)
    #expect(try assembler.accept(bytes("78 56 34 12 00 00 01 00 00 00 0c 00 00 01 02 03 04 05 06 07")) == .ignored)
    #expect(try assembler.accept(bytes("78 56 34 12 00 00 05 00 08 00 0c 00 08 09 0a 0b")) == .packet(Data(0..<12)))
    #expect(try assembler.accept(bytes("78 56 34 12 01 00 06 00 00 00 00 00")) == .end)
}
@Test func malformedRemoteFragmentsNeverSplice() throws {
    let first = bytes("78 56 34 12 00 00 01 00 00 00 0c 00 00 01 02 03 04 05 06 07")
    var assembler = RemoteAudioAssembler(maximum: 512)
    _ = try assembler.accept(first)
    #expect(try assembler.accept(first) == .ignored)
    var conflict = first; conflict[12] = 33
    #expect(throws: (any Error).self) { _ = try assembler.accept(conflict) }
    var missing = RemoteAudioAssembler(maximum: 512)
    #expect(throws: (any Error).self) { _ = try missing.accept(bytes("78 56 34 12 00 00 05 00 08 00 0c 00 08 09 0a 0b")) }
    var badEnd = RemoteAudioAssembler(maximum: 512)
    #expect(throws: (any Error).self) { _ = try badEnd.accept(bytes("78 56 34 12 00 00 07 00 00 00 00 00")) }
}
@Test func snapshotsAndInputGapsCannotGenerateButtonEdges() throws {
    var tracker = RemoteInputTracker()
    #expect(try tracker.accept(RemoteInput(bytes("2a 00 00 00 e8 03 00 00 00 01 01 00 00 00"))) == false)
    #expect(tracker.synchronized)
    #expect(try tracker.accept(RemoteInput(bytes("2b 00 00 00 e9 03 00 00 01 01 01 01 00 00"))))
    #expect(throws: (any Error).self) { _ = try tracker.accept(RemoteInput(bytes("2d 00 00 00 ea 03 00 00 02 01 01 00 00 00"))) }
    #expect(!tracker.synchronized)
    tracker.reset(); #expect(tracker.last == nil)
}
@Test func phoneDisplayFragmentationMatchesDraftAndRejectsInvalidArm() throws {
    var state = RemotePhoneState()
    state.names = ["Auto", "PC"]; state.resolved = "PC"; state.error = "Mic off"
    state.requestSnapshot = true; state.acknowledgedSequence = 42
    #expect(try state.fragments(transaction: 7, budget: 20) == [
        bytes("07 00 21 00 00 00 01 00 00 00 02 00 2a 00 00 00 04 41 75 74"),
        bytes("07 00 21 00 0e 00 6f 02 50 43 02 50 43 03 42 4c 45 07 4d 69"),
        bytes("07 00 21 00 1c 00 63 20 6f 66 66")])
    state.arm = true
    #expect(throws: (any Error).self) { _ = try state.fragments(transaction: 7, budget: 20) }
}
@Test func sourceScoringRejectsLostAndInvalidStreams() {
    #expect(SourceQuality.best([
        .init(id: "lost", snrDB: 80, clipping: 0, dropouts: 1, proximity: 1),
        .init(id: "clipped", snrDB: 20, clipping: 1, dropouts: 0, proximity: 1),
        .init(id: "clean", snrDB: 10, clipping: 0, dropouts: 0, proximity: 0.5),
        .init(id: "invalid", snrDB: .nan, clipping: 0, dropouts: 0, proximity: 1)]) == "clean")
}
@Test func continuousCaptureSplitsUtterancesWithoutWritingAudio() async throws {
    let source = EventFixture(script: [
        .frame(try AudioFrame(samples: [1000, 1000], timestamp: 0)),
        .frame(try AudioFrame(samples: [0, 0], timestamp: 0.001)),
        .frame(try AudioFrame(samples: [1000], timestamp: 0.002)), .interrupted])
    var slices: [[CaptureEvent]] = []
    for await slice in CaptureSegmenter(maximumSamples: 16, silenceSamples: 2).slices(from: source) {
        var events: [CaptureEvent] = []
        for await event in slice.events() { events.append(event) }
        slices.append(events)
    }
    #expect(slices.count == 2)
    #expect(slices[0].count == 2)
    #expect(slices[1].last == .interrupted)
}
private struct EventFixture: CaptureSource {
    let script: [CaptureEvent]
    func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<CaptureEvent> { AsyncStream { c in for event in script { c.yield(event) }; c.finish() } }
}

@Test func endedRemoteSegmentCannotBeReplayedIntoNewModeOrCapture() throws {
    var nextCapture = RemoteAudioAssembler(maximum: 512, afterSegment: 0x12345678)
    #expect(try nextCapture.accept(bytes("78 56 34 12 00 00 01 00 00 00 0c 00 00 01 02 03 04 05 06 07")) == .ignored)
}
