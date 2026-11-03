import Foundation
import XCTest
#if os(Linux)
import Glibc
#endif
@testable import KeyboardBridge

@MainActor private final class Destination: TextInserter {
    enum Interruption: Error { case crash }
    var texts: [String] = []
    var terminateProcess = false
    var interruptBeforeInsert = false
    var interruptAfterInsert = false
    func insertText(_ text: String) throws {
        if interruptBeforeInsert { throw Interruption.crash }
        texts.append(text)
        #if os(Linux)
        if terminateProcess { _exit(71) }
        #endif
        if interruptAfterInsert { throw Interruption.crash }
    }
}

final class KeyboardBridgeTests: XCTestCase {
    private func directories() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("shared"), root.appendingPathComponent("local"))
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func segment(_ text: String, age: TimeInterval = 0) -> CommittedSegment {
        CommittedSegment(id: UUID(), createdAt: now.addingTimeInterval(-age), text: text)
    }

    @MainActor func testOnlySuccessfulInsertionCreatesPositiveSharedReceipt() throws {
        let (_, shared, local) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        let success = segment("Synthetic success")
        try writer.enqueue(success, listening: false, now: now)
        XCTAssertFalse(try writer.insertionConfirmed(id: success.id, now: now))
        let destination = Destination()
        _ = try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now)
        XCTAssertTrue(try writer.insertionConfirmed(id: success.id, now: now))
        let uncertain = segment("Synthetic uncertainty")
        try writer.enqueue(uncertain, listening: false, now: now)
        destination.interruptAfterInsert = true
        XCTAssertThrowsError(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now))
        XCTAssertFalse(try writer.insertionConfirmed(id: uncertain.id, now: now))
        destination.interruptAfterInsert = false
        XCTAssertEqual(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now), 0)
        XCTAssertEqual(destination.texts.count, 2)
    }

    @MainActor func testCommitOrderingAndDeduplicationAcrossInstances() async throws {
        let (_, shared, local) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        let first = segment("Synthetic alpha", age: 1)
        let second = segment("Synthetic beta", age: 2)
        try writer.enqueue(first, listening: true, now: now)
        try writer.enqueue(second, listening: true, now: now)
        try writer.enqueue(first, listening: false, now: now)
        let destination = Destination()
        XCTAssertEqual(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now), 2)
        XCTAssertEqual(destination.texts, [first.text, second.text])
        XCTAssertEqual(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now), 0)
        XCTAssertFalse(try QueueReader(sharedDirectory: shared, localDirectory: local).status(now: now).listening)
    }

    @MainActor func testCrashMidDrainNeverRepeatsAttemptedSegment() async throws {
        let (_, shared, local) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        try writer.enqueue(segment("Synthetic first"), listening: false, now: now)
        try writer.enqueue(segment("Synthetic second"), listening: false, now: now)
        let interrupted = Destination()
        interrupted.interruptAfterInsert = true
        XCTAssertThrowsError(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: interrupted, now: now))
        // Discard reader as if the process died immediately after UIKit insertion.
        let restarted = Destination()
        try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: restarted, now: now)
        XCTAssertEqual(interrupted.texts, ["Synthetic first"])
        XCTAssertEqual(restarted.texts, ["Synthetic second"])
    }

    #if os(Linux)
    @MainActor func testProcessTerminationMidDrain() async throws {
        let (root, shared, local) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        try writer.enqueue(segment("Synthetic first"), listening: false, now: now)
        try writer.enqueue(segment("Synthetic second"), listening: false, now: now)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["KeyboardBridgeTests.KeyboardBridgeTests/testCrashWorker"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["KEYBOARD_BRIDGE_CRASH_ROOT": root.path], uniquingKeysWith: { _, new in new })
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 71)
        let destination = Destination()
        try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now)
        XCTAssertEqual(destination.texts, ["Synthetic second"])
    }

    @MainActor func testCrashWorker() async throws {
        guard let path = ProcessInfo.processInfo.environment["KEYBOARD_BRIDGE_CRASH_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        let destination = Destination()
        destination.terminateProcess = true
        try QueueReader(sharedDirectory: root.appendingPathComponent("shared"),
                        localDirectory: root.appendingPathComponent("local")).drain(into: destination, now: now)
        XCTFail("Child should terminate inside insertion")
    }
    #endif

    @MainActor func testCrashAfterReceiptBeforeInsertionLosesRatherThanDuplicates() async throws {
        let (_, shared, local) = try directories()
        try QueueWriter(sharedDirectory: shared).enqueue(segment("Synthetic lost"), listening: false, now: now)
        let interrupted = Destination()
        interrupted.interruptBeforeInsert = true
        XCTAssertThrowsError(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: interrupted, now: now))
        let restarted = Destination()
        XCTAssertEqual(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: restarted, now: now), 0)
        XCTAssertTrue(restarted.texts.isEmpty)
    }

    @MainActor func testSevenDayExpiryAtBoundaryAndProducerCleanup() async throws {
        let (_, shared, local) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        let old = segment("Synthetic expired")
        try writer.enqueue(old, listening: false, now: now)
        let later = now.addingTimeInterval(BridgePolicy.retention)
        let destination = Destination()
        XCTAssertEqual(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: later), 0)
        XCTAssertThrowsError(try writer.enqueue(old, listening: false, now: later))
        try writer.maintain(listening: false, now: later)
        let file = try String(contentsOf: shared.appendingPathComponent(BridgePolicy.queueFilename), encoding: .utf8)
        XCTAssertFalse(file.contains(old.text))
        XCTAssertThrowsError(try writer.enqueue(segment("Future", age: -1), listening: false, now: now))
    }

    @MainActor func testNoSendRejectsAllControlsAndNewlinesBeforeQueueAndAtDrain() async throws {
        let (_, shared, local) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        let forbidden = Array(0...31) + Array(127...159) + [0x2028, 0x2029]
        for value in forbidden {
            let text = "Synthetic" + String(UnicodeScalar(value)!)
            XCTAssertThrowsError(try writer.enqueue(segment(text), listening: false, now: now))
        }
        // Defense in depth: a corrupt/external producer cannot bypass drain validation.
        let unsafe = segment("Synthetic\n")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "listening": false,
            "segments": [["id": unsafe.id.uuidString, "createdAt": now.timeIntervalSinceReferenceDate, "text": unsafe.text]]])
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try data.write(to: shared.appendingPathComponent(BridgePolicy.queueFilename))
        let destination = Destination()
        XCTAssertThrowsError(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now))
        XCTAssertTrue(destination.texts.isEmpty)
        XCTAssertNoThrow(try BridgePolicy.validate("Synthetic café 😀"))
    }

    func testSizeCapRejectsWithoutReplacingLastGoodQueue() throws {
        let (_, shared, _) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        let file = shared.appendingPathComponent(BridgePolicy.queueFilename)
        XCTAssertThrowsError(try writer.enqueue(segment(String(repeating: "a", count: BridgePolicy.maxTextBytes + 1)), listening: false, now: now))
        let text = String(repeating: "a", count: BridgePolicy.maxTextBytes)
        var reachedCap = false
        for _ in 0..<32 {
            let previous = try? Data(contentsOf: file)
            do { try writer.enqueue(segment(text), listening: false, now: now) }
            catch BridgeError.capacity {
                XCTAssertEqual(try Data(contentsOf: file), previous)
                reachedCap = true
                break
            }
        }
        XCTAssertTrue(reachedCap)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, BridgePolicy.maxFileBytes)
    }

    @MainActor func testOversizedAndUnknownVersionFilesFailClosed() async throws {
        let (_, shared, local) = try directories()
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let file = shared.appendingPathComponent(BridgePolicy.queueFilename)
        let reader = QueueReader(sharedDirectory: shared, localDirectory: local)
        let destination = Destination()
        try Data(repeating: 32, count: BridgePolicy.maxFileBytes + 1).write(to: file)
        XCTAssertThrowsError(try reader.drain(into: destination, now: now))
        try Data("{\"version\":2,\"listening\":false,\"segments\":[]}".utf8).write(to: file)
        XCTAssertThrowsError(try reader.drain(into: destination, now: now))
        XCTAssertTrue(destination.texts.isEmpty)
    }
}

extension KeyboardBridgeTests {
    @MainActor func testNoSendRejectsCRLFAndControlCombiningClustersAtBothBoundaries() async throws {
        let (_, shared, local) = try directories()
        let writer = QueueWriter(sharedDirectory: shared)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for text in ["\r\n", "a\r\nb", "\n\u{0301}", "a\u{0000}\u{0301}b"] {
            XCTAssertThrowsError(try BridgePolicy.validate(text))
            let unsafe = segment(text)
            XCTAssertThrowsError(try writer.enqueue(unsafe, listening: false, now: now))
            // Model a corrupted queue that bypassed the app's enqueue validation.
            let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "listening": false,
                "segments": [["id": unsafe.id.uuidString, "createdAt": now.timeIntervalSinceReferenceDate, "text": text]]])
            try bytes.write(to: shared.appendingPathComponent(BridgePolicy.queueFilename))
            let destination = Destination()
            XCTAssertThrowsError(try QueueReader(sharedDirectory: shared, localDirectory: local).drain(into: destination, now: now))
            XCTAssertTrue(destination.texts.isEmpty)
        }
    }
}

extension KeyboardBridgeTests {
    func testDormantQueuePurgedFromDiskByRelaunchedWriter() throws {
        let (_, shared, _) = try directories()
        let fixture = segment("Synthetic dormant text")
        try QueueWriter(sharedDirectory: shared).enqueue(fixture, listening: false, now: now)
        let expired = now.addingTimeInterval(BridgePolicy.retention)
        try QueueWriter(sharedDirectory: shared).maintain(listening: false, now: expired)
        let bytes = try Data(contentsOf: shared.appendingPathComponent(BridgePolicy.queueFilename))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(fixture.text))
    }
}
