import Foundation
import XCTest
@testable import Pairing

#if os(Linux) || os(macOS)
final class NoiseURLSessionTests: XCTestCase, @unchecked Sendable {
    func testHTTPResponseCapRedirectTimeoutAndCancellation() async throws {
        try await testDeadline(seconds: 20) { [self] in
        // Synthetic loopback sidecar, never a remote HTTP fallback. Native phone
        // URLs come only from RelayClient's validated HTTPS origin.
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", #"""
import http.server, signal, time, threading, os
# Foundation's Process may inherit a blocked signal mask from a Swift worker.
# Ensure the helper can be reaped when the test's defer terminates it.
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
timer = threading.Timer(15, lambda: os._exit(124))
timer.daemon = True
timer.start()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/redirect':
            self.send_response(302); self.send_header('Location', '/ok'); self.end_headers(); return
        if self.path == '/slow': time.sleep(3)
        self.send_response(200)
        if self.path == '/large': self.send_header('Content-Length', '4097')
        self.end_headers()
        try:
            self.wfile.write(b'x' * 4097 if self.path in ('/large', '/stream') else b'{"joined":true}')
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#]
        process.standardOutput = pipe
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var bytes = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), byte.first != 10 { bytes += byte }
        let port = try XCTUnwrap(Int(String(decoding: bytes, as: UTF8.self)))
        let http = URLSessionRelayHTTP()
        func request(_ path: String) -> RelayRequest { .init(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, method: "POST", body: Data("{}".utf8)) }
        let ok = try await http.perform(request("ok"))
        XCTAssertEqual(ok.status, 200); XCTAssertEqual(ok.body, Data("{\"joined\":true}".utf8))
        for path in ["large", "stream", "redirect", "slow"] {
            do { _ = try await http.perform(request(path)); XCTFail("native adapter accepted \(path)") } catch {}
        }
        let cancellation = Task { try await http.perform(request("slow")) }; cancellation.cancel()
        do { _ = try await cancellation.value; XCTFail("cancelled HTTP completed") } catch {}
        }
    }
}
#endif
