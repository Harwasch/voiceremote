import Foundation

/// One complete Noise message per frame; LAN and relay adapters implement this.
/// send and receive must honor task cancellation. close must unblock pending I/O.
public protocol PairingTransport: Sendable {
    /// Existing authenticated Noise state only; never pairing/resume XX.
    func retainedSession() async
    func send(_ frame: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public extension PairingTransport {
    func retainedSession() async {}
}

private actor FrameQueue {
    private var frames: [Data] = []
    private var waiter: (UUID, CheckedContinuation<Data, any Error>)?
    private var closed = false
    func push(_ frame: Data) throws {
        guard !closed else { throw PairingError.closedTransport }
        if let (_, continuation) = waiter { waiter = nil; continuation.resume(returning: frame) }
        else {
            guard frames.count < 16 else { throw PairingError.invalidState }
            frames.append(frame)
        }
    }
    func pop() async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw PairingError.closedTransport }
        if !frames.isEmpty { return frames.removeFirst() }
        guard waiter == nil else { throw PairingError.invalidState }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = (id, $0) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let (pendingID, continuation) = waiter, pendingID == id {
            waiter = nil; continuation.resume(throwing: CancellationError())
        }
    }
    func close() {
        closed = true; frames.removeAll()
        waiter?.1.resume(throwing: PairingError.closedTransport); waiter = nil
    }
}

public struct InMemoryPairingTransport: PairingTransport {
    private let input: FrameQueue
    private let output: FrameQueue
    private init(input: FrameQueue, output: FrameQueue) { self.input = input; self.output = output }
    public static func pair() -> (Self, Self) {
        let a = FrameQueue(); let b = FrameQueue()
        return (Self(input: a, output: b), Self(input: b, output: a))
    }
    public func send(_ frame: Data) async throws {
        guard frame.count <= 65_535 else { throw PairingError.messageTooLarge }
        try await output.push(frame)
    }
    public func receive() async throws -> Data { try await input.pop() }
    public func close() async { await input.close(); await output.close() }
}
