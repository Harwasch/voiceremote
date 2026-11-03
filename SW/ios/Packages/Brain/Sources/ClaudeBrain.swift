import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BrainHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public init(data: Data, statusCode: Int) { self.data = data; self.statusCode = statusCode }
}

public protocol BrainHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> BrainHTTPResponse
}

/// Ephemeral sessions avoid transcript caches and cookies; redirects cannot leak request bodies.
public final class URLSessionBrainTransport: NSObject, BrainHTTPTransport, URLSessionTaskDelegate, Sendable {
    private let protocolClasses: [AnyClass]?
    public init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses; super.init() }
    public func send(_ request: URLRequest) async throws -> BrainHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BrainError.invalidResponse }
        guard data.count <= 1_048_576 else { throw BrainError.responseTooLarge }
        return BrainHTTPResponse(data: data, statusCode: http.statusCode)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ClaudeBrainConfiguration: Sendable {
    public let proxyURL: URL
    public let model: String
    public let apiVersion: String
    public init(proxyURL: URL, model: String = "claude-opus-5-5", apiVersion: String = "2026-10-21") throws {
        let normalizedHost = proxyURL.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard proxyURL.scheme == "https", let host = normalizedHost, !host.isEmpty,
              host != "anthropic.com", !host.hasSuffix(".anthropic.com"),
              proxyURL.user == nil, proxyURL.password == nil, proxyURL.query == nil, proxyURL.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiVersion.isEmpty else { throw BrainError.invalidConfiguration }
        self.proxyURL = proxyURL; self.model = model; self.apiVersion = apiVersion
    }
}

public struct ClaudeBrain: LlmBrain {
    private let configuration: ClaudeBrainConfiguration
    private let transport: any BrainHTTPTransport
    public init(configuration: ClaudeBrainConfiguration, transport: any BrainHTTPTransport = URLSessionBrainTransport()) {
        self.configuration = configuration; self.transport = transport
    }

    public func propose(_ request: BrainRequest) async throws -> BrainResponse {
        let tools = try ToolCatalog.tools()
        let body: [String: Any] = [
            "model": configuration.model, "max_tokens": 2048,
            "system": try BrainPrompts.system,
            "messages": [["role": "user", "content": try BrainPrompts.userData(request)]],
            "tools": tools, "tool_choice": ["type": "auto"]
        ]
        var http = URLRequest(url: configuration.proxyURL)
        http.httpMethod = "POST"; http.timeoutInterval = 60
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        // Proxy owns provider credentials and authenticates the phone outside this proposal client.
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let response = try await transport.send(http)
        guard (200..<300).contains(response.statusCode) else { throw BrainError.httpStatus(response.statusCode) }
        return try Self.decodeResponse(response.data, accountID: request.accountID)
    }

    static func decodeResponse(_ data: Data, accountID: String) throws -> BrainResponse {
        let root = try RawJSON.parse(data)
        // Provider metadata evolves and is never authority. Only original tool input
        // bytes cross the generated closed-schema boundary.
        guard let fields = root.fields,
              fields["role"]?.string == "assistant", fields["type"]?.string == "message",
              let blocks = fields["content"]?.elements,
              let stop = fields["stop_reason"]?.string else {
            throw BrainError.invalidResponse
        }
        if stop == "refusal" || fields["stop_details"]?.fields?["type"]?.string == "refusal"
            || blocks.contains(where: { $0.fields?["type"]?.string == "refusal" }) {
            return BrainResponse(outcome: .refused)
        }
        guard ["tool_use", "end_turn"].contains(stop) else { throw BrainError.invalidResponse }
        var proposals: [BrainProposal] = []
        var dropped = 0
        for block in blocks {
            guard let b = block.fields,
                  b["type"]?.string == "tool_use", let id = b["id"]?.string, !id.isEmpty,
                  let name = b["name"]?.string, ToolCatalog.names.contains(name),
                  let input = b["input"], input.fields?["kind"]?.string == name,
                  stop == "tool_use", proposals.count < 64 else { dropped += 1; continue }
            let result = ProposalDecoder.decodeItems([input], accountID: accountID)
            proposals.append(contentsOf: result.proposals); dropped += result.droppedCount
        }
        return BrainResponse(proposals: proposals, droppedCount: dropped)
    }
}

enum ToolCatalog {
    static let names: Set<String> = ["select_target", "open_resource", "delegate_task", "cancel_task", "prepare_send"]

    static func document() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "tool-call.schema", withExtension: "json"),
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var defs = root["$defs"] as? [String: Any] else { throw BrainError.invalidConfiguration }
        // Resolve the one external schema reference for provider portability.
        defs["Identifier"] = ["type": "string", "minLength": 1, "maxLength": 128]
        return ["$ref": "#/$defs/ToolCall", "$defs": defs]
    }

    static func tools() throws -> [[String: Any]] {
        let doc = try document()
        guard let defs = doc["$defs"] as? [String: Any],
              let union = defs["ToolCall"] as? [String: Any], let variants = union["oneOf"] as? [[String: String]] else {
            throw BrainError.invalidConfiguration
        }
        return try variants.map { variant in
            guard let ref = variant["$ref"], var schema = defs[String(ref.split(separator: "/").last!)] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any],
                  let kind = properties["kind"] as? [String: String], let name = kind["const"] else {
                throw BrainError.invalidConfiguration
            }
            schema["$defs"] = defs
            return ["name": name, "description": "Propose \(name) for review only; never execute. Include kind and no extra fields.",
                    "input_schema": schema]
        }
    }
}

extension BrainPrompts {
    /// The same schema accompanies JSON-text generation on Apple and MLX runtimes.
    public static var toolSchemaJSON: String {
        get throws { String(decoding: try JSONSerialization.data(withJSONObject: ToolCatalog.document(), options: [.sortedKeys]), as: UTF8.self) }
    }
}
