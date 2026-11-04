import Foundation
import XCTest

private enum TestDeadlineError: Error { case expired(String, UInt) }

/// Unstructured race intentionally returns even if a broken test double ignores
/// cancellation. Structured task groups would wait forever for that child.
private final class DeadlineResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false
    private var task: Task<Void, Never>?
    private var timer: DispatchWorkItem?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func install(task: Task<Void, Never>, timer: DispatchWorkItem) {
        lock.lock()
        if completed { lock.unlock(); task.cancel(); timer.cancel(); return }
        self.task = task; self.timer = timer; lock.unlock()
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation, task = self.task, timer = self.timer
        self.continuation = nil; self.task = nil; self.timer = nil
        lock.unlock()
        task?.cancel(); timer?.cancel(); continuation?.resume(with: result)
    }
}

func testDeadline<Value: Sendable>(seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line,
    _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let result = DeadlineResult<Value>(continuation)
        let task = Task {
            do { result.finish(.success(try await operation())) }
            catch { result.finish(.failure(error)) }
        }
        let timer = DispatchWorkItem { result.finish(.failure(TestDeadlineError.expired(String(describing: file), line))) }
        result.install(task: task, timer: timer)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    }
}

// DispatchSemaphore.wait is unavailable from async code on Apple platforms.
private func blockUntilSignalled(_ gate: DispatchSemaphore) { gate.wait() }

final class TestDeadlineTests: XCTestCase, @unchecked Sendable {
    func testCancellationIgnoringWaitStillHasADeadline() async throws {
        try await testDeadline {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        do {
            try await testDeadline(seconds: 0.01) { blockUntilSignalled(gate) }
            XCTFail("deadline did not fire")
        } catch is TestDeadlineError { }

        }
    }
}

#if os(Linux) || os(macOS)
let boundedPeerProcessScript = #"""
import os, signal, subprocess, sys, threading
child = None
stopping = False
def stop(*args):
    global stopping
    stopping = True
    if child is not None:
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
signal.signal(signal.SIGTERM, stop)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
child = subprocess.Popen(sys.argv[1:], start_new_session=True)
if stopping: stop()
timer = threading.Timer(90, stop)
timer.start()
try: sys.exit(child.wait())
finally:
    timer.cancel()
    stop()
"""#
#endif

#if os(Linux) || os(macOS)
extension TestDeadlineTests {
    func testChildWithBlockedTerminationSignalIsKilledAndReaped() async throws {
        try await testDeadline(seconds: 5) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "-c", boundedPeerProcessScript,
                "python3", "-u", "-c", "import signal,time; signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGTERM}); print('ready',flush=True); time.sleep(600)"]
            process.standardOutput = output
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let ready = try output.fileHandleForReading.read(upToCount: 6)
            XCTAssertEqual(ready, Data("ready\n".utf8))
            process.terminate()
            process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0)
        }
    }
}
#endif
