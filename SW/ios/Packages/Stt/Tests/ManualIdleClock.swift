import Foundation
@testable import Stt

/// Virtual monotonic time. Only the test advances it; suspensions expose explicit checkpoints.
final class ManualIdleClock: SttIdleClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Duration = .zero
    private struct Sleep {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var sleepers: [UUID: Sleep] = [:]
    let suspensions = AsyncStream<Duration>.makeStream()
    var now: Duration { lock.withLock { instant } }
    func advance(by amount: Duration) {
        precondition(amount >= .zero)
        let ready = lock.withLock {
            instant += amount
            let ready = sleepers.filter { $0.value.deadline <= instant }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for sleep in ready { sleep.continuation.resume() }
    }
    func sleep(until deadline: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = lock.withLock { () -> Int in
                    if Task.isCancelled { return -1 }
                    if deadline <= instant { return 1 }
                    sleepers[id] = Sleep(deadline: deadline, continuation: continuation)
                    return 0
                }
                if result < 0 { continuation.resume(throwing: CancellationError()) }
                else if result > 0 { continuation.resume() }
                else { suspensions.continuation.yield(deadline) }
            }
        } onCancel: {
            let sleep = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            sleep?.continuation.resume(throwing: CancellationError())
        }
    }
}
