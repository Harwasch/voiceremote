import Foundation
import Stt

public struct CaptureSlice: CaptureSource, Sendable {
    private let input: AsyncStream<CaptureEvent>
    init(_ input: AsyncStream<CaptureEvent>) { self.input = input }
    public func events() -> AsyncStream<CaptureEvent> { input }
    public func frames() -> AsyncStream<AudioFrame> {
        AsyncStream { output in
            let worker = Task {
                for await event in input {
                    guard case .frame(let frame) = event else { break }
                    output.yield(frame)
                }
                output.finish()
            }
            output.onTermination = { _ in worker.cancel() }
        }
    }
}

/// Bounded, in-memory utterances keep continuous capture independent of STT/Brain.
/// Silence threshold and segmentation timing are heuristics (TBC on owner speech).
/// No waveform fusion, audio storage, authorization or recognized-word inspection.
public struct CaptureSegmenter: Sendable {
    public let maximumSamples: Int
    public let silenceSamples: Int
    public init(maximumSamples: Int = 20 * 16_000, silenceSamples: Int = 12_800) {
        self.maximumSamples = max(1, maximumSamples); self.silenceSamples = max(1, silenceSamples)
    }
    public func slices(from source: any CaptureSource) -> AsyncStream<CaptureSlice> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { output in
            let worker = Task {
                var current: AsyncStream<CaptureEvent>.Continuation?
                var total = 0, quiet = 0
                var speech = false
                defer { current?.finish(); output.finish() }
                for await event in source.events() {
                    guard !Task.isCancelled else { return }
                    if current == nil {
                        let slice = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(1200))
                        current = slice.continuation; total = 0; quiet = 0; speech = false
                        if case .dropped = output.yield(CaptureSlice(slice.stream)) {
                            current?.yield(.interrupted); return
                        }
                    }
                    if case .dropped = current?.yield(event) {
                        current?.yield(.interrupted); return
                    }
                    switch event {
                    case .interrupted: return
                    case .frame(let frame):
                        total += frame.samples.count
                        let voiced = frame.samples.contains { abs(Int($0)) > 400 }
                        speech = speech || voiced
                        quiet = voiced ? 0 : quiet + frame.samples.count
                        if total >= maximumSamples || (speech && quiet >= silenceSamples) {
                            current?.finish(); current = nil
                        }
                    }
                }
            }
            output.onTermination = { _ in worker.cancel() }
        }
    }
}
