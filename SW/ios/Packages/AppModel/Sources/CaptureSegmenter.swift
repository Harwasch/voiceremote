import Foundation
import Stt

public enum CaptureBoundary: Equatable, Sendable { case open, silence, limit, end, interrupted }
private final class SliceBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var boundary = CaptureBoundary.open
    var value: CaptureBoundary { lock.withLock { boundary } }
    func set(_ value: CaptureBoundary) { lock.withLock { boundary = value } }
}

public struct CaptureSlice: CaptureSource, Sendable {
    private let input: AsyncStream<CaptureEvent>
    private let completion: SliceBoundary
    public var boundary: CaptureBoundary { completion.value }
    fileprivate init(_ input: AsyncStream<CaptureEvent>, completion: SliceBoundary) { self.input = input; self.completion = completion }
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
                var completion = SliceBoundary()
                var total = 0, quiet = 0
                var speech = false
                defer { if completion.value == .open { completion.set(.end) }; current?.finish(); output.finish() }
                for await event in source.events() {
                    guard !Task.isCancelled else { return }
                    if current == nil {
                        let slice = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(1200))
                        completion = SliceBoundary()
                        current = slice.continuation; total = 0; quiet = 0; speech = false
                        if case .dropped = output.yield(CaptureSlice(slice.stream, completion: completion)) {
                            current?.yield(.interrupted); return
                        }
                    }
                    if case .dropped = current?.yield(event) {
                        current?.yield(.interrupted); return
                    }
                    switch event {
                    case .interrupted: completion.set(.interrupted); return
                    case .frame(let frame):
                        total += frame.samples.count
                        let voiced = frame.samples.contains { abs(Int($0)) > 400 }
                        speech = speech || voiced
                        quiet = voiced ? 0 : quiet + frame.samples.count
                        if total >= maximumSamples || (speech && quiet >= silenceSamples) {
                            completion.set(speech && quiet >= silenceSamples ? .silence : .limit)
                            current?.finish(); current = nil
                        }
                    }
                }
            }
            output.onTermination = { _ in worker.cancel() }
        }
    }
}

/// Review intent boundaries never create executable command boundaries. Silence
/// commits one ambient intent permanently. Time slices retain the active intent
/// so corrections replace only its unfinished preview. Text rollover starts another bounded,
/// inferred intent instead of stopping an arbitrarily long meeting.
struct CaptureIntentBuffer {
    struct Revision {
        var id = UUID().uuidString
        var revision = 0
        var text = ""
    }
    private var active: Revision?
    private var committed: Revision?
    private(set) var rolledOver = false
    mutating func append(_ text: String, boundary: CaptureBoundary, deliberate: Bool) -> [Revision] {
        let correction = text.range(of: #"^\s*(?:no\b|actually\b|correction\b|i meant\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
        var next = active ?? Revision(), result: [Revision] = []
        var addition = (next.text.isEmpty ? "" : " ") + text
        if correction, !deliberate, next.text.count + addition.count > 16_384 {
            // Keep the correction's identity even when its earlier context is
            // full, so an old approval is invalidated before any rollover.
            next.text = ""; addition = text
        }
        if next.text.count + addition.count > 16_384 {
            // Do not retain or execute a truncated deliberate command.
            committed = next; next = Revision(); rolledOver = true
        }
        var remaining = addition[...]
        while !remaining.isEmpty {
            let room = 16_384 - next.text.count
            let part = remaining.prefix(room)
            next.text += part; remaining = remaining.dropFirst(part.count)
            next.revision += 1; result.append(next)
            if !remaining.isEmpty { committed = next; next = Revision(); rolledOver = true }
        }
        active = next
        if boundary == .silence, !deliberate { committed = next; active = nil }
        return result
    }
    mutating func finish() -> Revision? {
        guard var final = active ?? committed, !final.text.isEmpty else { return nil }
        final.revision += 1; return final
    }
}
