import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Pairing
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
    init(url: URL, headers: [String: String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", fakeScript, "bridge", url.absoluteString, try JSONEncoder().encode(headers).base64EncodedString()]
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
    let receives = AsyncStream<Void>.makeStream()
    let closes = AsyncStream<Void>.makeStream()
    func send(_ message: SocketMessage) async throws {}
    func receive() async throws -> SocketMessage {
        if closed { throw SttFailure.cancelled }
        receives.continuation.yield(())
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() {
        closed = true; waiter?.resume(throwing: SttFailure.cancelled); waiter = nil
        closes.continuation.yield(()); closes.continuation.finish()
    }
}
private struct StalledFactory: SttSocketFactory {
    let socket: StalledSocket
    func connect(to url: URL) async throws -> any SttSocket { socket }
}
private actor SuspendedFactory: SttSocketFactory {
    let started = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()
    func connect(to url: URL) async throws -> any SttSocket {
        started.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw SttFailure.cancelled }
        return StalledSocket()
    }
}
private struct FailingActivitySocket: SttSocket {
    func send(_ message: SocketMessage) async throws { throw SttFailure.transport }
    func receive() async throws -> SocketMessage { throw SttFailure.transport }
    func close() async {}
}

/// No autonomous timing: tests decide when I/O completes.
private actor ActivityTestSocket: SttSocket {
    let replies = AsyncStream<SocketMessage>.makeStream()
    let receives = AsyncStream<Void>.makeStream()
    let sent = AsyncStream<SocketMessage>.makeStream()
    func send(_ message: SocketMessage) async throws { sent.continuation.yield(message) }
    func receive() async throws -> SocketMessage {
        receives.continuation.yield(())
        var iterator = replies.stream.makeAsyncIterator()
        guard let value = await iterator.next() else { throw SttFailure.cancelled }
        return value
    }
    func reply(_ message: SocketMessage) { replies.continuation.yield(message) }
    func close() { replies.continuation.finish() }
}
private struct ActivityTestFactory: SttSocketFactory {
    let socket: ActivityTestSocket
    func connect(to url: URL) async throws -> any SttSocket { socket }
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
        // Exercise the exact activity wrapper used for FoundationSocket on Apple.
        // Await I/O completion before advancing time: no Task.sleep or scheduler deadline race.
        for inbound in [true, false] {
            let clock = ManualIdleClock()
            let idle = IdleTimeout(timeout: .seconds(60), clock: clock)
            let base = ActivityTestSocket()
            let socket = ActivitySocket(base: base, idle: idle)
            for _ in 0..<8 {
                clock.advance(by: .seconds(59))
                if inbound {
                    await base.reply(.text("{\"type\":\"Heartbeat\"}"))
                    _ = try await socket.receive()
                } else {
                    try await socket.send(.binary(Data(repeating: 0, count: 1600)))
                }
                XCTAssertEqual(idle.nextDeadline(), clock.now + .seconds(60))
                XCTAssertFalse(idle.expireIfIdle())
            }
            // Virtual session duration is 472 s, well beyond the former 60 s overall timer.
            clock.advance(by: .seconds(59))
            XCTAssertFalse(idle.expireIfIdle())
            clock.advance(by: .seconds(1))
            XCTAssertTrue(idle.expireIfIdle())
            XCTAssertNil(idle.nextDeadline())
            idle.activity() // A late I/O completion cannot revive an expired session.
            XCTAssertNil(idle.nextDeadline())
            await base.close()
        }
    }
    func testEngineWatchdogRechecksAnOldDeadlineAfterInboundActivity() async throws {
        let clock = ManualIdleClock()
        let socket = ActivityTestSocket()
        let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: URL(string: "wss://proxy.invalid/stt")!),
                                 sockets: ActivityTestFactory(socket: socket), timeout: .seconds(60), clock: clock)
        let audio = AsyncStream<AudioFrame>.makeStream()
        let output = AsyncStream<SttEvent>.makeStream()
        let consumer = Task {
            for await event in engine.transcribe(audio.stream, vocabulary: vocabulary) {
                output.continuation.yield(event)
            }
            output.continuation.finish()
            clock.suspensions.continuation.finish()
        }
        defer { consumer.cancel(); audio.continuation.finish() }
        var sent = socket.sent.stream.makeAsyncIterator()
        var receives = socket.receives.stream.makeAsyncIterator()
        var sleeps = clock.suspensions.stream.makeAsyncIterator()
        var events = output.stream.makeAsyncIterator()
        _ = await receives.next() // Connect installed; no audio or EOS has been sent.
        let initialDeadline = await sleeps.next()
        XCTAssertEqual(initialDeadline, .seconds(60))
        clock.advance(by: .seconds(59))
        await socket.reply(.text("{\"type\":\"Turn\",\"turn_order\":0,\"end_of_turn\":false,\"transcript\":\"Synthetic phrase.\"}"))
        let partial = await events.next()
        XCTAssertEqual(partial, .partial("Synthetic phrase.")) // Receive activity has been recorded.
        clock.advance(by: .seconds(1))
        let extendedDeadline = await sleeps.next()
        XCTAssertEqual(extendedDeadline, .seconds(119))
        guard extendedDeadline == .seconds(119) else { return }
        clock.advance(by: .seconds(58))
        await socket.reply(.text("{\"type\":\"Turn\",\"turn_order\":0,\"end_of_turn\":true,\"transcript\":\"Synthetic phrase.\"}"))
        let final = await events.next()
        XCTAssertEqual(final, .final("Synthetic phrase."))
        audio.continuation.finish()
        let terminate = await sent.next()
        XCTAssertEqual(terminate, .text("{\"type\":\"Terminate\"}"))
        await socket.reply(.text("{\"type\":\"Termination\"}"))
        let end = await events.next()
        XCTAssertNil(end)
        await consumer.value
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
        var receives = socket.receives.stream.makeAsyncIterator()
        var closes = socket.closes.stream.makeAsyncIterator()
        _ = await receives.next()
        consumer.cancel(); await consumer.value
        _ = await closes.next()
        let closed = await socket.closed; XCTAssertTrue(closed)
    }
    func testDeadlineIncludesConnectionEstablishment() async throws {
        let clock = ManualIdleClock()
        let factory = SuspendedFactory()
        let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: URL(string: "wss://proxy.invalid/stt")!),
                                 sockets: factory, timeout: .seconds(60), clock: clock)
        let consumer = Task { () -> [SttEvent] in
            var events: [SttEvent] = []
            for await event in engine.transcribe(ScriptedCaptureSource([]).frames(), vocabulary: vocabulary) { events.append(event) }
            clock.suspensions.continuation.finish()
            return events
        }
        defer { consumer.cancel() }
        var connects = factory.started.stream.makeAsyncIterator()
        var sleeps = clock.suspensions.stream.makeAsyncIterator()
        _ = await connects.next()
        let deadline = await sleeps.next()
        XCTAssertEqual(deadline, .seconds(60))
        clock.advance(by: .seconds(60))
        let events = await consumer.value
        XCTAssertEqual(events, [.failure(.timedOut)])
    }
    func testConnectedSocketTimesOutOnlyAfterInactivity() async throws {
        let clock = ManualIdleClock()
        let socket = ActivityTestSocket()
        let audio = AsyncStream<AudioFrame>.makeStream()
        let engine = CloudEngine(vendor: .assemblyAI, settings: try .init(url: URL(string: "wss://proxy.invalid/stt")!),
                                 sockets: ActivityTestFactory(socket: socket), timeout: .seconds(60), clock: clock)
        let consumer = Task { () -> [SttEvent] in
            var events: [SttEvent] = []
            for await event in engine.transcribe(audio.stream, vocabulary: vocabulary) { events.append(event) }
            clock.suspensions.continuation.finish()
            return events
        }
        defer { consumer.cancel(); audio.continuation.finish() }
        var receives = socket.receives.stream.makeAsyncIterator()
        var sleeps = clock.suspensions.stream.makeAsyncIterator()
        _ = await receives.next()
        let deadline = await sleeps.next()
        XCTAssertEqual(deadline, .seconds(60))
        clock.advance(by: .seconds(60))
        let events = await consumer.value
        XCTAssertEqual(events, [.failure(.timedOut)])
    }
    func testFailedIOAndStoppedWatchdogDoNotExtendTheDeadline() async {
        let clock = ManualIdleClock()
        let idle = IdleTimeout(timeout: .seconds(60), clock: clock)
        let socket = ActivitySocket(base: FailingActivitySocket(), idle: idle)
        clock.advance(by: .seconds(59))
        do { try await socket.send(.text("synthetic")); XCTFail("Expected transport failure") } catch {}
        do { _ = try await socket.receive(); XCTFail("Expected transport failure") } catch {}
        XCTAssertEqual(idle.nextDeadline(), .seconds(60))
        idle.stop()
        clock.advance(by: .seconds(100))
        idle.activity()
        XCTAssertNil(idle.nextDeadline())
        XCTAssertFalse(idle.expireIfIdle())
    }
    func testProxySettingsRejectSecretsVendorURLsAndInsecureRemote() throws {
        for url in ["ws://proxy.invalid", "wss://key:secret@proxy.invalid", "wss://proxy.invalid?token=secret",
                    "wss://api.elevenlabs.io/v1", "wss://streaming.assemblyai.com/v3/ws"] {
            XCTAssertThrowsError(try ProxySettings(url: URL(string: url)!))
        }
        XCTAssertNoThrow(try ProxySettings(url: URL(string: "wss://proxy.invalid/stt")!))
    }
}

private struct SyntheticProof: RelayProxyAuthorizer {
    func authorize(_ request: URLRequest, provider: String) async throws -> URLRequest {
        XCTAssertEqual(provider, "elevenlabs"); XCTAssertEqual(request.httpMethod, "GET")
        var signed = request
        signed.setValue("synthetic-challenge", forHTTPHeaderField: "X-Relay-Challenge")
        signed.setValue("synthetic-signature", forHTTPHeaderField: "X-Relay-Signature")
        return signed
    }
}
extension CloudTests {
    func testURLSessionFactoryCarriesProofHeadersThroughRealLinuxUpgrade() async throws {
        let server = try LocalWebSocketServer(vendor: .elevenLabs, scenario: "signed")
        let sockets = URLSessionSocketFactory(authorizer: SyntheticProof(), provider: "elevenlabs", open: { request in
            try BridgeSocket(url: request.url!, headers: request.allHTTPHeaderFields ?? [:])
        })
        let engine = CloudEngine(vendor: .elevenLabs, settings: try ProxySettings(url: server.url, allowInsecureLoopback: true), sockets: sockets)
        let source = ScriptedCaptureSource([try AudioFrame(samples: [-32768, 32767], timestamp: 0)])
        var events: [SttEvent] = []
        for await event in engine.transcribe(source.frames(), vocabulary: vocabulary) { events.append(event) }
        XCTAssertTrue(events.contains(.final("Synthetic phrase.")))
        XCTAssertFalse(events.contains { if case .failure = $0 { return true }; return false })
    }
}
