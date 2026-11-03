import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// No redirects, cookies or cache. Incremental control responses stop at 4096
/// bytes before buffering more. Only fixed metadata errors escape this adapter.
public struct URLSessionRelayHTTP: RelayHTTP {
    public init() {}
    public func perform(_ request: RelayRequest) async throws -> RelayResponse {
        let call = HTTPCall()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { call.start(request, continuation: $0) }
        } onCancel: { call.cancel() }
    }
}
private final class HTTPCall: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RelayResponse, any Error>?
    private var session: URLSession?
    private var bytes = Data()
    private var status: Int?
    private var finished = false
    func start(_ request: RelayRequest, continuation: CheckedContinuation<RelayResponse, any Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var wire = URLRequest(url: request.url); wire.httpMethod = request.method; wire.httpBody = request.body
        wire.allHTTPHeaderFields = request.headers
        let task = session.dataTask(with: wire)
        lock.unlock(); task.resume()
    }
    private func finish(_ result: Result<RelayResponse, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; bytes.removeAll()
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func cancel() { finish(.failure(CancellationError())) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(PairingError.invalidMessage))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let valid = lock.withLock {
            guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 4096 else { return false }
            status = response.statusCode; return !finished
        }
        completionHandler(valid ? .allow : .cancel)
        if !valid { finish(.failure(PairingError.messageTooLarge)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let valid = lock.withLock {
            guard !finished, data.count <= 4096 - bytes.count else { return false }
            bytes += data; return true
        }
        if !valid { finish(.failure(PairingError.messageTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<RelayResponse, any Error> = lock.withLock {
            if error != nil { return .failure(PairingError.closedTransport) }
            guard let status else { return .failure(PairingError.invalidMessage) }
            return .success(.init(status: status, body: bytes))
        }
        finish(result)
    }
}

public struct URLSessionWebSocketConnector: WebSocketConnector {
    public init() {}
    public func connect(_ request: RelayRequest) async throws -> WebSocketUpgrade {
        let opening = SocketOpening()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { opening.start(request, continuation: $0) }
        } onCancel: { opening.cancel() }
    }
}
private final class NativeWebSocket: WebSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let session: URLSession
    init(task: URLSessionWebSocketTask, session: URLSession) { self.task = task; self.session = session }
    func send(text: String) async throws {
        try await withTaskCancellationHandler { try await task.send(.string(text)) }
        onCancel: { self.task.cancel(with: .goingAway, reason: nil) }
    }
    func receive() async throws -> WebSocketMessage {
        try await withTaskCancellationHandler {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let bytes): return .binary(bytes)
            @unknown default: return .closed
            }
        } onCancel: { self.task.cancel(with: .goingAway, reason: nil) }
    }
    func ping() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if error != nil { continuation.resume(throwing: PairingError.closedTransport) }
                    else { continuation.resume() }
                }
            }
        } onCancel: { self.task.cancel(with: .goingAway, reason: nil) }
    }
    func close() async { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
private final class SocketOpening: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebSocketUpgrade, any Error>?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false
    func start(_ request: RelayRequest, continuation: CheckedContinuation<WebSocketUpgrade, any Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil); self.session = session
        var wire = URLRequest(url: request.url); wire.allHTTPHeaderFields = request.headers
        let task = session.webSocketTask(with: wire); task.maximumMessageSize = 16_384; self.task = task
        lock.unlock(); task.resume()
    }
    func cancel(error: any Error = PairingError.closedTransport) {
        lock.lock(); finished = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let task = self.task; self.task = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
        continuation?.resume(throwing: error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil); cancel()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard let response = webSocketTask.response as? HTTPURLResponse else { cancel(); return }
        guard response.statusCode == 101 else { cancel(error: RelayError.httpRefused(response.statusCode)); return }
        lock.lock()
        guard !finished else { lock.unlock(); cancel(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        self.session = nil; self.task = nil
        lock.unlock()
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        continuation?.resume(returning: .init(socket: NativeWebSocket(task: webSocketTask, session: session), headers: headers))
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 { cancel(error: RelayError.httpRefused(response.statusCode)) }
        else if error != nil { cancel() }
    }
}
