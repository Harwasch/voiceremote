import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Pairing
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

private final class UnknownLengthRelayResponse: HTTPURLResponse, @unchecked Sendable {
    override var expectedContentLength: Int64 { -1 }
}

final class NoiseURLSessionDelegateTests: XCTestCase, @unchecked Sendable {
    func testDeclaredLengthIsCheckedEvenWhenFoundationReportsUnknown() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://relay.example.invalid/control")!
        let task = session.dataTask(with: url) // Never resumed.
        for declared in ["4097", "18446744073709551616", "-1", "invalid"] {
            let call = HTTPCall()
            let response = try XCTUnwrap(UnknownLengthRelayResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["content-length": declared]))
            call.urlSession(session, dataTask: task, didReceive: response) { disposition in
                XCTAssertEqual(disposition, .cancel, "declared=\(declared), expected=\(response.expectedContentLength)")
            }
        }
    }

    func testRedirectResponseIsRejectedWithoutRelyingOnRedirectCallback() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://relay.example.invalid/control")!
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302,
            httpVersion: "HTTP/1.1", headerFields: ["Location": "/other"]))
        HTTPCall().urlSession(session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .cancel)
        }
    }

    func testHTTPRejectionSurvivesReentrantCancellationAndLateCompletion() async throws {
        try await testDeadline {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let request = RelayRequest(url: URL(string: "https://relay.example.invalid/control")!, method: "POST")
            let task = session.dataTask(with: request.url)
            for path in ["header", "stream", "redirect"] {
                let call = HTTPCall()
                let expected: PairingError = path == "redirect" ? .invalidMessage : .messageTooLarge
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: path == "header" ? ["Content-Length": "4097"] : [:]))
                if path == "redirect" {
                    call.urlSession(session, task: task, willPerformHTTPRedirection: response,
                        newRequest: URLRequest(url: request.url)) { redirected in
                        XCTAssertNil(redirected)
                        call.cancel()
                    }
                } else {
                    call.urlSession(session, dataTask: task, didReceive: response) { disposition in
                        if path == "header" { call.cancel() }
                    }
                    if path == "stream" {
                        call.urlSession(session, dataTask: task, didReceive: Data(repeating: 32, count: 4096))
                        call.urlSession(session, dataTask: task, didReceive: Data([32]))
                    }
                }
                call.cancel()
                call.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
                call.urlSession(session, task: task, didCompleteWithError: nil)
                call.urlSession(session, dataTask: task, didReceive: Data([32]))
                do {
                    _ = try await withCheckedThrowingContinuation { call.start(request, continuation: $0) }
                    XCTFail("rejection lost: \(path)")
                } catch { XCTAssertEqual(error as? PairingError, expected, "path=\(path), error=\(error)") }
            }
        }
    }

    func testSocketRedirectDecisionSurvivesReentrantCancellation() async throws {
        try await testDeadline {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let request = RelayRequest(url: URL(string: "wss://relay.example.invalid/connect")!, method: "GET")
            let task = session.webSocketTask(with: request.url) // Never resumed.
            let opening = SocketOpening()
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url, statusCode: 302,
                httpVersion: "HTTP/1.1", headerFields: ["Location": "wss://other.example.invalid/"]))
            opening.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: request.url)) { redirected in
                XCTAssertNil(redirected)
                opening.cancel(error: CancellationError())
            }
            opening.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            do {
                _ = try await withCheckedThrowingContinuation { opening.start(request, continuation: $0) }
                XCTFail("socket redirect accepted")
            } catch { XCTAssertEqual(error as? PairingError, .closedTransport, "error=\(error)") }
        }
    }

    func testAlreadyCancelledSocketConnectDoesNotStartIO() async throws {
        try await testDeadline {
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await URLSessionWebSocketConnector().connect(.init(
                    url: URL(string: "wss://relay.example.invalid/connect")!, method: "GET"))
            }
            do { _ = try await cancelled.value; XCTFail("cancelled socket opened") }
            catch { XCTAssertTrue(error is CancellationError, "error=\(error)") }
        }
    }
}

#if os(Linux) || os(macOS)
private struct HTTPFixtureFailure: Error, CustomStringConvertible {
    let description: String
}

/// Synthetic loopback sidecar. Startup never depends on Foundation pipe buffering,
/// and all unfinished responses wait for client cancellation rather than server EOF.
private final class RelayHTTPFixture {
    let process = Process()
    let output = Pipe(), errors = Pipe()
    private(set) var port = 0
    private var launched = false

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", #"""
import http.server, socketserver, signal, threading, os
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
timer = threading.Timer(30, lambda: os._exit(124))
timer.daemon = True
timer.start()
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self): self.do_POST()
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        path = self.path.strip('/')
        if path == 'socket-slow':
            try: self.connection.recv(1)
            except ConnectionResetError: pass
            return
        if path.startswith('redirect-'):
            self.send_response(int(path.split('-')[1]))
            self.send_header('Location', '/ok')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_response(200)
        if not path.endswith('untyped'):
            self.send_header('Content-Type', 'application/octet-stream')
        if path.startswith('large'):
            self.send_header('Content-Length', '4097')
        elif path.startswith('stream'):
            self.send_header('Transfer-Encoding', 'chunked')
        else:
            self.send_header('Content-Length', str(4096 if path == 'exact' else 15))
        self.end_headers()
        self.wfile.flush()
        try:
            if path.startswith('large'):
                # Supply sniffing bytes, but never the full declared body.
                self.wfile.write(b' ' * 1024)
            elif path.startswith('stream'):
                for chunk in (b' ' * 4096, b' '):
                    self.wfile.write(('%x\r\n' % len(chunk)).encode() + chunk + b'\r\n')
                    self.wfile.flush()
                # Deliberately omit the terminal chunk.
            elif path == 'exact':
                self.wfile.write(b' ' * 4096)
                self.wfile.flush()
                return
            elif path != 'slow':
                self.wfile.write(b'{"joined":true}')
                self.wfile.flush()
                return
            self.wfile.flush()
            self.connection.recv(1) # Only the client closes these responses.
        except (BrokenPipeError, ConnectionResetError): pass
class LoopbackServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer normally reverse-resolves 127.0.0.1 during construction.
        # This fixture needs only the bound port, with no runner DNS dependency.
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]
server = LoopbackServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        launched = true
        do {
            let line = try readReadyLine()
            guard let parsed = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...65535).contains(parsed) else {
                throw HTTPFixtureFailure(description: "invalid readiness line: \(String(reflecting: line))")
            }
            port = parsed
        } catch {
            stop()
            let stderr = try errors.fileHandleForReading.readToEnd() ?? Data()
            throw HTTPFixtureFailure(description: "HTTP helper startup: \(error); exit=\(process.terminationStatus); " +
                "stderr=\(String(reflecting: String(decoding: stderr, as: UTF8.self))); " +
                "platform=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
    }

    private func readReadyLine() throws -> String {
        let deadline = ContinuousClock.now + .seconds(5)
        var bytes = Data()
        let descriptor = output.fileHandleForReading.fileDescriptor
        while ContinuousClock.now < deadline, bytes.count < 256 {
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&entry, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw HTTPFixtureFailure(description: "readiness poll errno=\(errno)")
            }
            if result == 0 { continue }
            var byte: UInt8 = 0
            let count = read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw HTTPFixtureFailure(description: "readiness deadline/EOF; stdout=\(String(reflecting: String(decoding: bytes, as: UTF8.self)))")
    }

    func request(_ path: String) -> RelayRequest {
        .init(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, method: "POST",
              headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
    }

    func stop() {
        guard launched else { return }
        // Reap even if the helper inherited blocked signals or is stuck in I/O.
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        launched = false
    }
    deinit { stop() }
}

final class NoiseURLSessionTests: XCTestCase, @unchecked Sendable {
    private func perform(_ request: RelayRequest, through http: URLSessionRelayHTTP) async throws -> RelayResponse {
        try await testDeadline(seconds: 5) { try await http.perform(request) }
    }

    private func diagnostic(_ path: String, _ started: ContinuousClock.Instant, _ error: any Error) -> String {
        let nsError = error as NSError
        return "path=\(path), elapsed=\(started.duration(to: .now)), error=\(String(reflecting: error)), " +
            "type=\(String(reflecting: type(of: error))), domain=\(nsError.domain), code=\(nsError.code), " +
            "platform=\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    func testHTTPResponseCapRedirectTimeoutAndCancellation() async throws {
        try await testDeadline { [self] in
            let server = try RelayHTTPFixture()
            defer { server.stop() }
            let http = URLSessionRelayHTTP()
            for path in ["ok", "exact"] {
                let started = ContinuousClock.now
                do {
                    let response = try await perform(server.request(path), through: http)
                    XCTAssertEqual(response.status, 200, "path=\(path)")
                    XCTAssertEqual(response.body, path == "exact" ? Data(repeating: 32, count: 4096) : Data("{\"joined\":true}".utf8), "path=\(path)")
                } catch { XCTFail(diagnostic(path, started, error)) }
            }
            for path in ["large", "large-untyped", "stream", "stream-untyped"] {
                let started = ContinuousClock.now
                do {
                    _ = try await perform(server.request(path), through: http)
                    XCTFail("native adapter accepted \(path)")
                } catch {
                    XCTAssertEqual(error as? PairingError, .messageTooLarge, diagnostic(path, started, error))
                }
            }
            for code in [301, 302, 303, 307, 308] {
                let path = "redirect-\(code)", started = ContinuousClock.now
                do {
                    _ = try await perform(server.request(path), through: http)
                    XCTFail("native adapter followed/accepted \(path)")
                } catch {
                    XCTAssertEqual(error as? PairingError, .invalidMessage, diagnostic(path, started, error))
                }
            }
            let started = ContinuousClock.now
            do {
                _ = try await perform(server.request("slow"), through: http)
                XCTFail("header-only stalled response completed")
            } catch {
                XCTAssertEqual(error as? PairingError, .closedTransport, diagnostic("slow", started, error))
                XCTAssertLessThan(started.duration(to: .now), .seconds(5), diagnostic("slow", started, error))
            }
            for delay in [Duration.zero, .milliseconds(100)] {
                let started = ContinuousClock.now
                let request = server.request("slow")
                let cancellation = Task { try await http.perform(request) }
                if delay != .zero { try await Task.sleep(for: delay) }
                cancellation.cancel()
                do {
                    _ = try await testDeadline(seconds: 5) { try await cancellation.value }
                    XCTFail("cancelled HTTP completed")
                }
                catch { XCTAssertTrue(error is CancellationError, diagnostic("cancel/\(delay)", started, error)) }
            }
        }
    }

    #if os(macOS)
    // Linux FoundationNetworking may not support native WebSockets. Exercise
    // the Apple adapter against an unfinished upgrade on the actual Mac runner.
    func testNativeSocketCancellationDuringUpgrade() async throws {
        try await testDeadline { [self] in
            let server = try RelayHTTPFixture()
            defer { server.stop() }
            let request = RelayRequest(url: URL(string: "ws://127.0.0.1:\(server.port)/socket-slow")!, method: "GET")
            let started = ContinuousClock.now
            let opening = Task { try await URLSessionWebSocketConnector().connect(request) }
            try await Task.sleep(for: .milliseconds(100))
            opening.cancel()
            do {
                _ = try await testDeadline(seconds: 5) { try await opening.value }
                XCTFail("cancelled native upgrade opened")
            }
            catch { XCTAssertTrue(error is CancellationError, diagnostic("socket-cancel", started, error)) }
        }
    }
    #endif
}
#endif
