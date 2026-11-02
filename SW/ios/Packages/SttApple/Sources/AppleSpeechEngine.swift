import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia
import Stt

/// https://developer.apple.com/documentation/speech/speechanalyzer
/// https://developer.apple.com/videos/play/wwdc2025/277/
/// Host handles Speech permission and capture; no automatic model download on the utterance path.
/// UNVERIFIED until macOS CI compilation and owner iPhone testing.
public actor AppleSpeechEngine: SttEngine {
    public nonisolated let descriptor = EngineDescriptor(id: "apple", version: "SpeechAnalyzer-iOS26", location: .onDevice)
    private let locale: Locale
    private var busy = false
    public init(locale: Locale = Locale(identifier: "en-US")) { self.locale = locale }
    public func modelAvailable() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }
    public func prepare(allowDownload: Bool = false) async throws {
        guard !busy, SpeechTranscriber.isAvailable else { throw SttFailure.unavailable }
        busy = true; defer { busy = false }
        if await modelAvailable() { return }
        guard allowDownload else { throw SttFailure.unavailable }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
    public nonisolated func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
        AsyncStream { output in
            let worker = Task { await self.run(audio, output: output) }
            output.onTermination = { _ in worker.cancel() }
        }
    }
    private func run(_ audio: AsyncStream<AudioFrame>, output: AsyncStream<SttEvent>.Continuation) async {
        guard !busy else { output.yield(.failure(.unavailable)); output.finish(); return }
        busy = true; defer { busy = false; output.finish() }
        guard await modelAvailable() else { output.yield(.failure(.unavailable)); return }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                             reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputs = AsyncStream<AnalyzerInput>.makeStream()
        do {
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(AudioFrame.sampleRate), channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: sourceFormat, to: format) else { throw SttFailure.invalidAudio }
            converter.primeMethod = .none
            try await analyzer.start(inputSequence: inputs.stream)
            let feeder = Task {
                do {
                    var tailTime: TimeInterval = 0
                    for await frame in audio {
                        try Task.checkCancellation()
                        if frame.samples.isEmpty { continue }
                        let buffer = try Self.convert(frame, from: sourceFormat, to: format, converter: converter)
                        if buffer.frameLength > 0 {
                            inputs.continuation.yield(AnalyzerInput(buffer: buffer,
                                bufferStartTime: CMTime(seconds: frame.timestamp, preferredTimescale: 16_000)))
                        }
                        tailTime = frame.timestamp + Double(frame.samples.count) / Double(AudioFrame.sampleRate)
                    }
                    // Drain any converter-held tail before closing the analyzer input.
                    for buffer in try Self.drain(converter, format: format) {
                        inputs.continuation.yield(AnalyzerInput(buffer: buffer,
                            bufferStartTime: CMTime(seconds: tailTime, preferredTimescale: 16_000)))
                        tailTime += Double(buffer.frameLength) / format.sampleRate
                    }
                    inputs.continuation.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    inputs.continuation.finish()
                    await analyzer.cancelAndFinishNow()
                    if !Task.isCancelled { output.yield(.failure((error as? SttFailure) ?? .unavailable)) }
                }
            }
            defer { feeder.cancel(); inputs.continuation.finish() }
            try await withTaskCancellationHandler {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    output.yield(result.isFinal ? .final(text) : .partial(text))
                }
                await feeder.value
            } onCancel: {
                feeder.cancel(); inputs.continuation.finish()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            if !Task.isCancelled { output.yield(.failure((error as? SttFailure) ?? .unavailable)) }
        }
    }
    private static func drain(_ converter: AVAudioConverter, format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw SttFailure.invalidAudio }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                state.pointee = .endOfStream; return nil
            }
            guard error == nil, status != .error else { throw SttFailure.invalidAudio }
            if buffer.frameLength > 0 { buffers.append(buffer) }
            if status != .haveData || buffer.frameLength == 0 { return buffers }
        }
    }
    private static func convert(_ frame: AudioFrame, from source: AVAudioFormat, to target: AVAudioFormat,
                                converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frame.samples.count)),
              let channel = input.floatChannelData?[0] else { throw SttFailure.invalidAudio }
        input.frameLength = AVAudioFrameCount(frame.samples.count)
        for (index, value) in frame.floats.enumerated() { channel[index] = value }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / source.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw SttFailure.invalidAudio }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { throw SttFailure.invalidAudio }
        return output
    }
}
