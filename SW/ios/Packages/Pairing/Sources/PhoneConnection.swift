import Foundation
import VoiceRemoteProtocol

/// Production phone connection. One reader, serialized writes, correlated replies.
/// A timeout never resends text; a new connection requires fresh Noise resume.
public actor PhoneConnection {
    public let session: ApplicationSession
    private let transport: any PairingTransport
    private let accountID: String
    private let deviceID: String
    private var tail: Task<Void, Error>?
    private var pending: [String: (UUID, CheckedContinuation<InnerMessage, Error>)] = [:]
    private var preparationID: String?
    private struct ReportedState: Equatable {
        let mode: Mode
        let capture: CaptureState
        let listening: Bool
    }
    private var reportedState: ReportedState?
    public init(session: ApplicationSession, transport: any PairingTransport) {
        self.session = session; self.transport = transport
        accountID = session.peer.device.account_id; deviceID = session.peer.device.device_id
    }
    public func send(_ message: InnerMessage) async throws {
        let previous = tail, session = session, transport = transport
        let task = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await session.send(message, transport: transport)
        }
        tail = task
        try await task.value
    }
    /// Unchanged state is sent on a focus heartbeat too, keeping idle desktop
    /// sessions alive without treating microphone selection as actual capture.
    public func publishState(phoneID: String, mode: Mode, capture: CaptureState, listening: Bool, heartbeat: Bool = false) async throws {
        let state = ReportedState(mode: mode, capture: capture, listening: listening)
        guard heartbeat || reportedState != state else { return }
        reportedState = state
        try await send(.modeState(ModeState(account_id: accountID, device_id: phoneID, mode: mode)))
        try await send(.captureStateReport(CaptureStateReport(account_id: accountID, device_id: phoneID,
            capture_state: capture, listening: listening)))
    }
    /// Run continuously from the host's sole reader. Late outcomes are returned
    /// too, so durable history can reconcile even after the request timed out.
    public func receive() async throws -> InnerMessage {
        do {
            let message = try await session.receive(transport: transport)
            let key: String?
            switch message {
            case .targetReady(let value) where value.target_device_id == deviceID:
                key = "prepare:" + value.request_id
            case .dictationOutcome(let value) where value.target_device_id == deviceID:
                key = "segment:" + value.segment_id
            default: key = nil
            }
            if let key { pending.removeValue(forKey: key)?.1.resume(returning: message) }
            return message
        } catch { await close(); throw error }
    }
    private func fail(_ key: String, token: UUID, _ error: Error) {
        guard pending[key]?.0 == token else { return }
        pending.removeValue(forKey: key)?.1.resume(throwing: error)
    }
    private func request(_ message: InnerMessage, key: String, timeout: Duration) async throws -> InnerMessage {
        guard pending[key] == nil, pending.count < 64 else { throw PairingError.invalidState }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[key] = (token, continuation)
                Task {
                    do { try await self.send(message) }
                    catch { self.fail(key, token: token, error) }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    self.fail(key, token: token, PairingError.noMessage)
                }
            }
        } onCancel: { Task { await self.fail(key, token: token, CancellationError()) } }
    }
    public func prepare(timeout: Duration = .seconds(3)) async throws {
        preparationID = nil
        let id = UUID().uuidString
        let reply = try await request(.targetPrepare(TargetPrepare(account_id: accountID, request_id: id,
            target_device_id: deviceID)), key: "prepare:" + id, timeout: timeout)
        guard case .targetReady(let ready) = reply, ready.ready else { throw PairingError.invalidState }
        preparationID = id
    }
    public func insert(_ text: DictationText, timeout: Duration = .seconds(10)) async throws -> DictationOutcome {
        guard text.target_device_id == deviceID, let preparationID else { throw PairingError.invalidState }
        let prepared = DictationText(account_id: text.account_id, segment_id: text.segment_id,
            revision: text.revision, state: text.state, target_device_id: text.target_device_id,
            text: text.text, preparation_id: preparationID)
        let reply = try await request(.dictationText(prepared), key: "segment:" + text.segment_id, timeout: timeout)
        guard case .dictationOutcome(let value) = reply else { throw PairingError.invalidMessage }
        return value
    }
    /// Queries durable receiver identity; never carries text or triggers insertion.
    public func reconcile(segmentID: String, timeout: Duration = .seconds(3)) async throws -> DictationOutcome {
        let reply = try await request(.dictationQuery(DictationQuery(account_id: accountID, segment_id: segmentID,
            target_device_id: deviceID)), key: "segment:" + segmentID, timeout: timeout)
        guard case .dictationOutcome(let value) = reply else { throw PairingError.invalidMessage }
        return value
    }
    public func close() async {
        let waiters = pending.values; pending.removeAll(); preparationID = nil
        for (_, waiter) in waiters { waiter.resume(throwing: PairingError.closedTransport) }
        tail?.cancel()
        await session.close(transport: transport)
    }
}

/// Probe only while connecting, before any application text. A failed LAN
/// handshake closes that path before relay is tried. No write is replayed.
public enum PreferredConnection {
    public static func connect<T: Sendable>(lan: @Sendable () async throws -> T,
        relay: (@Sendable () async throws -> T)?) async throws -> T {
        do { return try await lan() }
        catch {
            try Task.checkCancellation()
            guard let relay else {
                if error is CancellationError { throw PairingError.noMessage }
                throw error
            }
            return try await relay()
        }
    }
    /// Discovery can yield several same-room advertisements. Authentication,
    /// rather than advertisement order, selects the peer. Failed attempts must
    /// close their transports before returning (pairing/resume already do).
    public static func tryLAN<Candidate: Sendable, Value: Sendable>(
        candidates: AsyncThrowingStream<Candidate, Error>,
        attempt: @Sendable (Candidate) async throws -> Value
    ) async throws -> Value {
        var lastError: any Error = PairingError.noMessage
        do {
            for try await candidate in candidates {
                try Task.checkCancellation()
                do { return try await attempt(candidate) }
                catch { try Task.checkCancellation(); lastError = error }
            }
        } catch {
            try Task.checkCancellation()
            if !(error is CancellationError) { lastError = error }
        }
        try Task.checkCancellation()
        if lastError is CancellationError { throw PairingError.noMessage }
        throw lastError
    }

}
