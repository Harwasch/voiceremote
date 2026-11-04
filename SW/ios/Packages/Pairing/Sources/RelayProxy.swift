import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// WHATWG URLSearchParams serialization. Pair order and repeated terms are significant.
public enum RelayQuery {
    public static func encode(_ items: [URLQueryItem]) -> String {
        func form(_ text: String) -> String {
            text.utf8.map { byte in
                switch byte {
                case 65...90, 97...122, 48...57, 42, 45, 46, 95: String(UnicodeScalar(byte))
                case 32: "+"
                default: String(format: "%%%02X", byte)
                }
            }.joined()
        }
        return items.map { form($0.name) + "=" + form($0.value ?? "") }.joined(separator: "&")
    }
    public static func canonical(_ url: URL) throws -> Data {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PairingError.invalidMessage }
        func decode(_ text: Substring) -> String {
            let bytes = Array(text.utf8); var result: [UInt8] = []; var i = 0
            func hex(_ byte: UInt8) -> UInt8? {
                switch byte {
                case 48...57: byte - 48
                case 65...70: byte - 55
                case 97...102: byte - 87
                default: nil
                }
            }
            while i < bytes.count {
                if bytes[i] == 43 { result.append(32) }
                else if bytes[i] == 37, i + 2 < bytes.count, let high = hex(bytes[i+1]), let low = hex(bytes[i+2]) {
                    result.append(high * 16 + low); i += 2
                } else { result.append(bytes[i]) }
                i += 1
            }
            return String(decoding: result, as: UTF8.self)
        }
        let items = (parts.percentEncodedQuery ?? "").split(separator: "&").map { pair in
            let split = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return URLQueryItem(name: decode(split[0]), value: split.count == 2 ? decode(split[1]) : "")
        }
        let query = encode(items)
        return Data((query.isEmpty ? "" : "?" + query).utf8)
    }
}

public protocol RelayProxyAuthorizer: Sendable {
    func authorize(_ request: URLRequest, provider: String) async throws -> URLRequest
}

extension RelayClient: RelayProxyAuthorizer {
    public func proxyURL(provider: String) throws -> URL {
        guard ["elevenlabs", "assemblyai", "anthropic"].contains(provider) else { throw PairingError.invalidMessage }
        // The same validated origin and tenant boundary used for room controls.
        return baseURL.appendingPathComponent("proxy/" + provider)
    }
    public func authorize(_ request: URLRequest, provider: String) async throws -> URLRequest {
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw PairingError.invalidMessage }
        let bytes: Data
        if provider == "anthropic" {
            guard request.httpMethod == "POST", parts.query == nil, request.httpBodyStream == nil else { throw PairingError.invalidMessage }
            bytes = request.httpBody ?? Data()
        } else {
            guard ["elevenlabs", "assemblyai"].contains(provider), request.httpMethod == "GET",
                  request.httpBody == nil else { throw PairingError.invalidMessage }
            bytes = try RelayQuery.canonical(url)
            // Normalize only for comparing the signed room route, never the query.
            parts.scheme = parts.scheme == "wss" ? "https" : parts.scheme == "ws" ? "http" : parts.scheme
        }
        parts.query = nil
        guard parts.url == (try proxyURL(provider: provider)) else { throw PairingError.wrongAccount }
        var signed = request
        // Credentials can only come from relay challenges. Never forward a bearer/vendor key.
        signed.setValue(nil, forHTTPHeaderField: "Authorization")
        signed.setValue(nil, forHTTPHeaderField: "x-api-key")
        signed.setValue(nil, forHTTPHeaderField: "xi-api-key")
        for (name, value) in try await authorization(operation: "proxy/" + provider, body: bytes) {
            signed.setValue(value, forHTTPHeaderField: name)
        }
        return signed
    }
}
