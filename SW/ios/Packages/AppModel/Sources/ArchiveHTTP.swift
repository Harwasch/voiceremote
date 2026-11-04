// Purpose: bounded archive HTTP reads. Inputs: audit-archive v2.
// Verification: portable compilation; production HTTP/device behavior unverified.
import Foundation
import Pairing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// No redirects, cookies or cache. Incremental control responses stop at 2_100_000
/// bytes before buffering more. Only fixed metadata errors escape this adapter.
public struct URLSessionArchiveHTTP: RelayHTTP {
    public init() {}
    public func perform(_ request: RelayRequest) async throws -> RelayResponse {
        guard request.url.scheme == "https", request.url.user == nil, request.url.password == nil,
              request.url.query == nil, request.url.fragment == nil, request.body.count <= 2_100_000 else { throw PairingError.invalidMessage }
        let call = ArchiveHTTPCall()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { call.start(request, continuation: $0) }
        } onCancel: { call.cancel() }
    }
}
private final class ArchiveHTTPCall: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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
            guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 2_100_000 else { return false }
            status = response.statusCode; return !finished
        }
        completionHandler(valid ? .allow : .cancel)
        if !valid { finish(.failure(PairingError.messageTooLarge)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let valid = lock.withLock {
            guard !finished, data.count <= 2_100_000 - bytes.count else { return false }
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

