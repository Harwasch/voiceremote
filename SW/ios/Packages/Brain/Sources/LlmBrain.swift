import Foundation
import VoiceRemoteProtocol

/// This boundary produces data for review. It has no command, policy or execution dependency.
public protocol LlmBrain: Sendable {
    func propose(_ request: BrainRequest) async throws -> BrainResponse
}

public enum BrainWorkload: String, Codable, Sendable {
    case automatic, simpleRouting, multiStep, ambient
}

public struct BrainRequest: Sendable {
    public let accountID: String
    public let transcript: String
    /// Registry/session descriptions are data, even when supplied by an agent.
    public let context: String
    public let workload: BrainWorkload

    public init(accountID: String, transcript: String, context: String, workload: BrainWorkload = .automatic) {
        self.accountID = accountID
        self.transcript = transcript
        self.context = context
        self.workload = workload
    }
}

/// Only the validating decoder can construct a proposal. It cannot encode an AuthorizedCommand.
public struct BrainProposal: Equatable, Sendable {
    public let tool: ToolCall
    init(validated tool: ToolCall) { self.tool = tool }

    public var accountID: String {
        switch tool {
        case .selectTargetTool(let t): t.account_id
        case .openResourceTool(let t): t.account_id
        case .delegateTaskTool(let t): t.account_id
        case .cancelTaskTool(let t): t.account_id
        case .prepareSendTool(let t): t.account_id
        }
    }

    /// Stable semantic key: includes destination, account, recipient, session and every argument.
    /// Normalize natural-language instructions only; identifiers, URIs and send previews stay exact.
    var normalizedIntent: String {
        let data = try! ProtocolCodec.encode(tool) // Already validated, immutable generated type.
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let instruction = object["instruction"] as? String {
            object["instruction"] = instruction
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let sorted = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: sorted, as: UTF8.self)
    }
}

public enum BrainOutcome: Equatable, Sendable { case proposed, refused }

public struct BrainResponse: Sendable {
    public let proposals: [BrainProposal]
    public let droppedCount: Int
    public let routingNotice: BrainRoutingNotice?
    public let outcome: BrainOutcome
    public init(proposals: [BrainProposal] = [], droppedCount: Int = 0, routingNotice: BrainRoutingNotice? = nil,
                outcome: BrainOutcome = .proposed) {
        self.proposals = outcome == .refused ? [] : proposals
        self.droppedCount = max(0, droppedCount)
        self.routingNotice = routingNotice
        self.outcome = outcome
    }
}

public enum BrainError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidResponse, unavailable, offline, httpStatus(Int), responseTooLarge
}

public enum BrainPrompts {
    public static var system: String {
        // A missing resource is a packaging failure, never an excuse to run without instructions.
        get throws {
            guard let url = Bundle.module.url(forResource: "proposal-system", withExtension: "txt") else {
                throw BrainError.invalidConfiguration
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    public static func userData(_ request: BrainRequest) throws -> String {
        struct Payload: Encodable {
            let account_id: String
            let untrusted_transcript: String
            let untrusted_context: String
        }
        let data = try JSONEncoder().encode(Payload(account_id: request.accountID,
            untrusted_transcript: request.transcript, untrusted_context: request.context))
        return String(decoding: data, as: UTF8.self)
    }
}
