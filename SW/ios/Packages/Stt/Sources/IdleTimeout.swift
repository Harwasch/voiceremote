import Foundation

/// A monotonic timeline shared by activity recording and the idle watchdog.
/// Implementations must honor task cancellation while sleeping.
public protocol SttIdleClock: Sendable {
    var now: Duration { get }
    func sleep(until deadline: Duration) async throws
}

public struct ContinuousIdleClock: SttIdleClock {
    private let origin = ContinuousClock.now
    public init() {}
    public var now: Duration { origin.duration(to: ContinuousClock.now) }
    public func sleep(until deadline: Duration) async throws {
        try await ContinuousClock().sleep(until: origin.advanced(by: deadline))
    }
}

/// I/O completion records activity synchronously, before another actor hop can delay it.
/// The lock serializes activity, expiry and stop; an old wakeup must recheck the current deadline.
final class IdleTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: any SttIdleClock
    private let timeout: Duration
    private var deadline: Duration?
    init(timeout: Duration, clock: any SttIdleClock) {
        self.timeout = timeout; self.clock = clock
        deadline = clock.now + timeout
    }
    func activity() {
        lock.withLock {
            if deadline != nil { deadline = clock.now + timeout }
        }
    }
    func nextDeadline() -> Duration? { lock.withLock { deadline } }
    func expireIfIdle() -> Bool {
        lock.withLock {
            guard let deadline, clock.now >= deadline else { return false }
            self.deadline = nil
            return true
        }
    }
    func stop() { lock.withLock { deadline = nil } }
}
