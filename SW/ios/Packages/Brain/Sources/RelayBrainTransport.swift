import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Pairing

/// Signs ClaudeBrain's final body bytes. No reserialization between digest and upload.
public struct RelayBrainTransport: BrainHTTPTransport {
    private let authorizer: any RelayProxyAuthorizer
    private let upstream: any BrainHTTPTransport
    public init(authorizer: any RelayProxyAuthorizer, upstream: any BrainHTTPTransport = URLSessionBrainTransport()) {
        self.authorizer = authorizer; self.upstream = upstream
    }
    public func send(_ request: URLRequest) async throws -> BrainHTTPResponse {
        try await upstream.send(authorizer.authorize(request, provider: "anthropic"))
    }
}
