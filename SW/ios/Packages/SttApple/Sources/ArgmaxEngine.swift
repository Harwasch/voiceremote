#if ENABLE_ARGMAX && canImport(Argmax)
import Foundation
@preconcurrency import Argmax
import Stt

/// Public API only, UNVERIFIED: no licence, private SDK or Apple compiler available here.
/// https://app.argmaxinc.com/docs/examples/real-time-transcription
/// https://app.argmaxinc.com/docs/examples/custom-vocabulary
/// https://app.argmaxinc.com/docs/guides/managing-models
/// The licensed host initializes ArgmaxSDK and supplies a loaded WhisperKitPro configured with
/// parakeet-v2_476MB + .parakeetRepo and preloaded customVocabularyConfig; never bundle models.
public actor ArgmaxEngine: SttEngine {
    public nonisolated let descriptor = EngineDescriptor(id: "argmax", version: "Pro-Parakeet-v2-unverified", location: .onDevice)
    private let kit: WhisperKitPro
    private var busy = false
    public init(loadedKit: WhisperKitPro) { kit = loadedKit }
    public nonisolated func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
        AsyncStream { output in
            let worker = Task { await self.run(audio, vocabulary: vocabulary, output: output) }
            output.onTermination = { _ in worker.cancel() }
        }
    }
    private func run(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary,
                     output: AsyncStream<SttEvent>.Continuation) async {
        guard !busy else { output.yield(.failure(.unavailable)); output.finish(); return }
        busy = true; defer { busy = false; output.finish() }
        do {
            try kit.setCustomVocabulary(vocabulary.terms)
            let options = DecodingOptionsPro(base: .init(verbose: false, task: .transcribe,
                skipSpecialTokens: true, wordTimestamps: true), transcribeInterval: 0.1)
            let session = kit.makeStreamSession(options: options)
            let input = AsyncStream<[Float]>.makeStream()
            let feeder = Task {
                for await frame in audio {
                    if Task.isCancelled { break }
                    input.continuation.yield(frame.floats)
                }
                input.continuation.finish()
            }
            defer { feeder.cancel(); input.continuation.finish() }
            try await withTaskCancellationHandler {
                await session.start(audioInputStream: input.stream)
                for try await result in session.results {
                    try Task.checkCancellation()
                    if let text = result.hypothesisText, !text.isEmpty { output.yield(.partial(text)) }
                    if !result.text.isEmpty { output.yield(.final(result.text)) }
                }
            } onCancel: {
                feeder.cancel(); input.continuation.finish()
            }
        } catch {
            if !Task.isCancelled { output.yield(.failure((error as? SttFailure) ?? .unavailable)) }
        }
    }
}
#endif

import Stt

/// Lets the settings UI report licence availability without importing the private SDK.
@MainActor public enum ArgmaxBuild {
    public private(set) static var engine: (any SttEngine)?
    #if ENABLE_ARGMAX && canImport(Argmax)
    /// Licensed host installs only after SDK initialization and model loading succeed.
    public static func install(loadedKit: WhisperKitPro) { engine = ArgmaxEngine(loadedKit: loadedKit) }
    #endif
    public static func remove() { engine = nil }
    public static var enabled: Bool {
        #if ENABLE_ARGMAX && canImport(Argmax)
        true
        #else
        false
        #endif
    }
}
