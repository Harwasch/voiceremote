import Foundation
import XCTest
@testable import Stt

private let fakeScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("FakeWebSocket.py").path
private func line(_ file: FileHandle) throws -> Data {
    var data = Data()
    while let byte = try file.read(upToCount: 1), !byte.isEmpty {
        if byte[0] == 10 { return data }
        data.append(byte)
    }
    throw SttFailure.transport
}
private final class LocalWebSocketServer {
    let process = Process()
    let url: URL
    init(vendor: CloudEngine.Vendor, scenario: String = "normal") throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", fakeScript, "server", vendor.rawValue, scenario]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let port = String(decoding: try line(output.fileHandleForReading), as: UTF8.self)
        url = URL(string: "ws://127.0.0.1:\(port)/proxy")!
    }
    deinit { if process.isRunning { process.terminate() }; process.waitUntilExit() }
}
/// Test-only bridge: uses real loopback HTTP upgrade + masked RFC6455 frames. No Linux URLSession WS dependency.
private final class BridgeSocket: SttSocket, @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    init(url: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", fakeScript, "bridge", url.absoluteString]
        process.standardInput = input; process.standardOutput = output
        try process.run()
    }
    func send(_ message: SocketMessage) async throws {
        let object: [String: String]
        switch message {
        case .text(let text): object = ["text": text]
        case .binary(let data): object = ["binary": data.base64EncodedString()]
        }
        var data = try JSONEncoder().encode(object); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func receive() async throws -> SocketMessage {
        try await Task.detached { [self] in
            let data = try line(output.fileHandleForReading)
            let object = try JSONDecoder().decode([String: String].self, from: data)
            if let text = object["text"] { return .text(text) }
            throw SttFailure.invalidResponse
        }.value
    }
    func close() async { if process.isRunning { process.terminate() } }
}
private struct BridgeFactory: SttSocketFactory {
    func connect(to url: URL) async throws -> any SttSocket { try BridgeSocket(url: url) }
}
private actor StalledSocket: SttSocket {
    var waiter: CheckedContinuation<SocketMessage, any Error>?
    var closed = false
    func send(_ message: SocketMessage) async throws {}
    func receive() async throws -> SocketMessage {
        if closed { throw SttFailure.cancelled }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() {
        closed = true; waiter?.resume(throwing: SttFailure.cancelled); waiter = nil
    }
}
private struct StalledFactory: SttSocketFactory {
    let socket: StalledSocket
    func connect(to url: URL) async throws -> any SttSocket { socket }
}
private struct SlowFactory: SttSocketFactory {
    func connect(to url: URL) async throws -> any SttSocket {
        try await Task.sleep(for: .seconds(5)); return StalledSocket()
    }
}

private actor ActivityTestSocket: SttSocket {
    let replies = AsyncStream<SocketMessage>.makeStream()
    let heartbeatOnly: Bool
    var count = 0
    init(heartbeatOnly: Bool = false) { self.heartbeatOnly = heartbeatOnly }
    func send(_ message: SocketMessage) async throws {
        if !heartbeatOnly, case .text(let text) = message, text.contains("Terminate") {
            replies.continuation.yield(.text("{\"type\":\"Turn\",\"turn_order\":0,\"end_of_turn\":true,\"transcript\":\"Synthetic phrase.\"}"))
            replies.continuation.yield(.text("{\"type\":\"Termination\"}"))
        }
    }
    func receive() async throws -> SocketMessage {
        if heartbeatOnly {
            try await Task.sleep(for: .milliseconds(30)); count += 1
            return .text(count <= 8 ? "{\"type\":\"Heartbeat\"}" : "{\"type\":\"Termination\"}")
        }
        var iterator = replies.stream.makeAsyncIterator()
        guard let value = await iterator.next() else { throw SttFailure.cancelled }
        return value
    }
    func close() { replies.continuation.finish() }
}
private struct ActivityTestFactory: SttSocketFactory {
    let socket: ActivityTestSocket
    func connect(to url: URL) async throws -> any SttSocket { socket }
}
private struct PacedTestSource: CaptureSource {
    func frames() -> AsyncStream<AudioFrame> {
        AsyncStream { output in
            let task = Task {
                for index in 0..<8 {
                    do { try await Task.sleep(for: .milliseconds(30)) } catch { break }
                    output.yield(try! AudioFrame(samples: Array(repeating: 0, count: 800), timestamp: Double(index) * 0.05))
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor final class CloudTests: XCTestCase {
    let vocabulary = Vocabulary(userID: "synthetic", terms: ["Codex"])
    func testBothVendorsParseAgainstLocalFakeWebSocketServer() async throws {
        for vendor in [CloudEngine.Vendor.elevenLabs, .assemblyAI] {
            let server = try LocalWebSocketServer(vendor: vendor)
            let engine = CloudEngine(vendor: vendor, settings: try .init(url: server.url, allowInsecureLoopback: true),
                                     sockets: BridgeFactory(), timeout: .seconds(3))
            let source = ScriptedCaptureSource([try AudioFrame(samples: [-32768, 32767], timestamp: 0)])
            var events: [SttEvent] = []
            for await event in engine.transcribe(source.frames(), vocabulary: vocabulary) { events.append(event) }
            XCTAssertTrue(events.contains(.partial("synthetic")), "\(vendor)")
            XCTAssertEqual(events.filter { if case .final = $0 { return true }; return false },
                           vendor == .elevenLabs ? [.final("Synthetic phrase.")] : [.final("Synthetic phrase."), .final("Second segment.")])
            XCTAssertFalse(events.contains { if case .failure = $0 { return true }; return false })
        }
    }
    func testElevenLabsAcknowledgesIntermediateCommitBeforeEOS() async throws {
        let server = try LocalWebSocketServer(vendor: .elevenLabs, scenario: "segmented")
        let engine = CloudEngine(vendor: .elevenLabs, settings: try .init(url: server.url, allowInsecureLoopback: true),
                                 sockets: BridgeFactory(), timeout: .seconds(5))
        // A single oversized capture frame is split into bounded chunks and two commits.
        let source = ScriptedCaptureSource([try AudioFrame(samples: Array(repeating: 0, count: 320000) + [-32768, 32767], timestamp: 0)])
        var finals: [String] = []
        var failed = false
        for await event in engine.transcribe(source.frames(), vocabulary: vocabulary) {
            if case .final(let text) = event { finals.append(text) }
            if case .failure = event { failed = true }
        }
        XCTAssertFalse(failed)
        XCTAssertEqual(finals, ["First segment.", "Synthetic phrase."])
    }
    func testElevenLabsExactCommitBoundaryPublishesFinalBeforeClosing() async throws {
        let server = try LocalWebSocketServer(vendor: .elevenLabs, scenario: "boundary")
        let engine = CloudEngine(vendor: .elevenLabs, settings: try .init(url: server.url, allowInsecureLoopback: true),
                                 sockets: BridgeFactory(), timeout: .seconds(5))
        let source = ScriptedCaptureSource([try AudioFrame(samples: Array(repeating: 0, count: 320000), timestamp: 0)])
        var events: [SttEvent] = []
        for await event in engine.transcribe(source.frames(), vocabulary: vocabulary) { events.append(event) }
        XCTAssertEqual(events.filter { if case .final = $0 { return true }; return false }, [.final("First segment.")])
        XCTAssertFalse(events.contains { if case .failure = $0 { return true }; return false })
    }
    func testActiveStreamsOutliveIdleTimeoutWithOutboundOrInboundActivity() async throws {
        for heartbeat in [true, false] {
            let socket = ActivityTestSocket(heartbeatOnly: heartbeat)
            let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: URL(string: "wss://proxy.invalid/stt")!),
                                     sockets: ActivityTestFactory(socket: socket), timeout: .milliseconds(100))
            let source: any CaptureSource = heartbeat ? ScriptedCaptureSource([]) : PacedTestSource()
            var events: [SttEvent] = []
            for await event in engine.transcribe(source.frames(), vocabulary: vocabulary) { events.append(event) }
            XCTAssertFalse(events.contains(.failure(.timedOut)))
            if !heartbeat { XCTAssertTrue(events.contains(.final("Synthetic phrase."))) }
        }
    }
    func testAssemblyRechunksTinyAndOversizedFramesAndPadsOnlyEOSTail() async throws {
        let server = try LocalWebSocketServer(vendor: .assemblyAI, scenario: "chunks")
        let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: server.url, allowInsecureLoopback: true), sockets: BridgeFactory())
        let frames = try [AudioFrame(samples: Array(repeating: 1, count: 13), timestamp: 0),
                          AudioFrame(samples: Array(repeating: 1, count: 16800), timestamp: 0.001)]
        var events: [SttEvent] = []
        for await event in engine.transcribe(ScriptedCaptureSource(frames).frames(), vocabulary: vocabulary) { events.append(event) }
        XCTAssertTrue(events.contains(.final("Synthetic phrase.")))
        XCTAssertFalse(events.contains { if case .failure = $0 { return true }; return false })
    }
    func testDocumentedNonfatalMessagesDoNotKillEitherVendorOrAddText() async throws {
        for vendor in [CloudEngine.Vendor.elevenLabs, .assemblyAI] {
            let server = try LocalWebSocketServer(vendor: vendor, scenario: "informational")
            let engine = CloudEngine(vendor: vendor, settings: try .init(url: server.url, allowInsecureLoopback: true), sockets: BridgeFactory())
            var events: [SttEvent] = []
            for await event in engine.transcribe(ScriptedCaptureSource([try AudioFrame(samples: [-32768, 32767], timestamp: 0)]).frames(), vocabulary: vocabulary) { events.append(event) }
            XCTAssertTrue(events.contains(.final("Synthetic phrase.")))
            XCTAssertFalse(events.contains { if case .failure = $0 { return true }; return false })
            XCTAssertFalse(events.contains(.final("must not become transcript")))
        }
    }
    func testAssemblyTerminationPreservesLatestUnfinishedPartialIncludingEmptyClosingTurn() async throws {
        for scenario in ["partial_tail", "empty_tail"] {
            let server = try LocalWebSocketServer(vendor: .assemblyAI, scenario: scenario)
            let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: server.url, allowInsecureLoopback: true), sockets: BridgeFactory())
            var events: [SttEvent] = []
            for await event in engine.transcribe(ScriptedCaptureSource([try AudioFrame(samples: [-32768, 32767], timestamp: 0)]).frames(), vocabulary: vocabulary) { events.append(event) }
            XCTAssertTrue(events.contains(.final("unfinished synthetic text")))
        }
    }
    func testProviderErrorsAndMalformedJSONAreSanitized() async throws {
        for vendor in [CloudEngine.Vendor.elevenLabs, .assemblyAI] {
            for scenario in ["error", "malformed"] {
                let server = try LocalWebSocketServer(vendor: vendor, scenario: scenario)
                let engine = CloudEngine(vendor: vendor, settings: try .init(url: server.url, allowInsecureLoopback: true),
                                         sockets: BridgeFactory(), timeout: .seconds(2))
                var events: [SttEvent] = []
                for await event in engine.transcribe(ScriptedCaptureSource([]).frames(), vocabulary: vocabulary) { events.append(event) }
                XCTAssertTrue(events.contains { if case .failure = $0 { return true }; return false })
            }
        }
    }
    func testCancellationClosesStalledSocket() async throws {
        let socket = StalledSocket()
        let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: URL(string: "wss://proxy.invalid/stt")!),
                                 sockets: StalledFactory(socket: socket))
        let consumer = Task {
            for await _ in engine.transcribe(ScriptedCaptureSource([]).frames(), vocabulary: vocabulary) {}
        }
        try await Task.sleep(for: .milliseconds(20)); consumer.cancel(); await consumer.value
        for _ in 0..<50 {
            if await socket.closed { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let closed = await socket.closed; XCTAssertTrue(closed)
    }
    func testDeadlineIncludesConnectionEstablishment() async throws {
        let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: URL(string: "wss://proxy.invalid/stt")!),
                                 sockets: SlowFactory(), timeout: .milliseconds(10))
        let clock = ContinuousClock(); let start = clock.now
        var events: [SttEvent] = []
        for await event in engine.transcribe(ScriptedCaptureSource([]).frames(), vocabulary: vocabulary) { events.append(event) }
        XCTAssertEqual(events, [.failure(.timedOut)])
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }
    func testConnectedSocketTimesOutOnlyAfterInactivity() async throws {
        let socket = StalledSocket()
        let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: URL(string: "wss://proxy.invalid/stt")!),
                                 sockets: StalledFactory(socket: socket), timeout: .milliseconds(20))
        var events: [SttEvent] = []
        for await event in engine.transcribe(ScriptedCaptureSource([]).frames(), vocabulary: vocabulary) { events.append(event) }
        XCTAssertEqual(events, [.failure(.timedOut)])
    }
    func testProxySettingsRejectSecretsVendorURLsAndInsecureRemote() throws {
        for url in ["ws://proxy.invalid", "wss://key:secret@proxy.invalid", "wss://proxy.invalid?token=secret",
                    "wss://api.elevenlabs.io/v1", "wss://streaming.assemblyai.com/v3/ws"] {
            XCTAssertThrowsError(try ProxySettings(url: URL(string: url)!))
        }
        XCTAssertNoThrow(try ProxySettings(url: URL(string: "wss://proxy.invalid/stt")!))
    }
}
