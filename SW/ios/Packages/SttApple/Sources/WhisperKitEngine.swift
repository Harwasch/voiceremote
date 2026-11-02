import Foundation
@preconcurrency import WhisperKit
import Stt

/// MIT WhisperKit dependency; no upstream source copied. API pinned to 0.14.1:
/// https://github.com/argmaxinc/WhisperKit/tree/v0.14.1
/// Apple compilation, device inference, streaming latency and accuracy are UNVERIFIED.
public actor WhisperKitEngine: SttEngine {
    public nonisolated let descriptor = EngineDescriptor(id: "whisperkit", version: "0.14.1-small.en", location: .onDevice)
    private var kit: WhisperKit?
    private var busy = false
    public init() {}
    public var modelAvailable: Bool { kit != nil }

    /// Explicit on-demand provisioning. Downloads to Application Support/cache, never the app bundle.
    /// Host obtains user consent/connectivity first; offline utterances never invoke this method.
    public func prepare(modelFolder: URL? = nil, allowDownload: Bool = false) async throws {
        guard !busy else { throw SttFailure.unavailable }
        busy = true; defer { busy = false }
        guard modelFolder != nil || allowDownload else { throw SttFailure.unavailable }
        let config = WhisperKitConfig(model: "small.en", modelFolder: modelFolder?.path,
                                      verbose: false, logLevel: .none, load: true, download: allowDownload)
        kit = try await WhisperKit(config)
    }
    public nonisolated func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
        AsyncStream { output in
            let worker = Task { await self.run(audio, vocabulary: vocabulary, output: output) }
            output.onTermination = { _ in worker.cancel() }
        }
    }
    private func run(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary,
                     output: AsyncStream<SttEvent>.Continuation) async {
        guard let kit, !busy else { output.yield(.failure(.unavailable)); output.finish(); return }
        busy = true; defer { busy = false; output.finish() }
        do {
            var samples: [Float] = []
            var lastPartialCount = 0
            var options = DecodingOptions()
            options.verbose = false
            options.concurrentWorkerCount = 1
            options.promptTokens = kit.tokenizer?.encode(text: vocabulary.terms.joined(separator: ", "))
            for await frame in audio {
                try Task.checkCancellation()
                // Bounded in-memory utterance, no raw audio writes. Long dictation session chunking is host-owned.
                guard samples.count + frame.samples.count <= AudioFrame.sampleRate * 120 else { throw SttFailure.invalidAudio }
                samples.append(contentsOf: frame.floats)
                if samples.count - lastPartialCount >= AudioFrame.sampleRate {
                    let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                    output.yield(.partial(results.map(\.text).joined()))
                    lastPartialCount = samples.count
                }
            }
            try Task.checkCancellation()
            if samples.isEmpty { output.yield(.final("")); return }
            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            output.yield(.final(results.map(\.text).joined()))
        } catch {
            if !Task.isCancelled { output.yield(.failure((error as? SttFailure) ?? .unavailable)) }
        }
    }
}
