import Foundation
import Brain
#if VOICE_REMOTE_ENABLE_MLX && canImport(MLXLLM) && canImport(MLXHuggingFace)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

public struct MLXBrainConfiguration: Sendable {
    public let modelID: String
    public let allowOnDemandDownload: Bool
    public init(modelID: String, allowOnDemandDownload: Bool = false) {
        self.modelID = modelID; self.allowOnDemandDownload = allowOnDemandDownload
    }
}

/// Both build flag and explicit runtime opt-in are required before loading/downloading an open model.
public actor MLXBrain: LlmBrain {
    private let configuration: MLXBrainConfiguration
    #if VOICE_REMOTE_ENABLE_MLX && canImport(MLXLLM) && canImport(MLXHuggingFace)
    private var container: ModelContainer?
    #endif

    public init(configuration: MLXBrainConfiguration) { self.configuration = configuration }

    public func propose(_ request: BrainRequest) async throws -> BrainResponse {
        guard configuration.allowOnDemandDownload, !configuration.modelID.isEmpty else { throw BrainError.unavailable }
        #if VOICE_REMOTE_ENABLE_MLX && canImport(MLXLLM) && canImport(MLXHuggingFace)
        if container == nil {
            container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: configuration.modelID))
        }
        guard let container else { throw BrainError.unavailable }
        let instructions = try BrainPrompts.system + "\nAllowed ToolCall schema:\n" + BrainPrompts.toolSchemaJSON
        // No tool dispatch closure: even a tool-capable open model produces review data only.
        let session = ChatSession(container, instructions: instructions)
        let output = try await session.respond(to: BrainPrompts.userData(request))
        return ProposalDecoder.decode(Data(output.utf8), accountID: request.accountID)
        #else
        throw BrainError.unavailable
        #endif
    }
}
