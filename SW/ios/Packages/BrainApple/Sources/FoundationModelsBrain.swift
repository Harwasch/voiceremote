import Foundation
import Brain
#if canImport(FoundationModels)
import FoundationModels

/// Apple-only thin adapter. Availability/quality and compilation remain unverified until macOS CI.
@available(iOS 26.0, macOS 26.0, *)
public actor FoundationModelsBrain: LlmBrain {
    public init() {}

    public func propose(_ request: BrainRequest) async throws -> BrainResponse {
        guard case .available = SystemLanguageModel.default.availability else { throw BrainError.unavailable }
        // A fresh session prevents one transcript's untrusted instructions becoming conversation history.
        // No Foundation Models executable tools are registered.
        let instructions = try BrainPrompts.system + "\nAllowed ToolCall schema:\n" + BrainPrompts.toolSchemaJSON
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: BrainPrompts.userData(request))
        return ProposalDecoder.decode(Data(response.content.utf8), accountID: request.accountID)
    }
}
#endif
