import Foundation

/// Mono signed PCM16 at 16 kHz. Timestamp is seconds on the capture's monotonic timeline.
/// Capture adapters resample before this boundary; samples and timing survive A/B replay unchanged.
public struct AudioFrame: Sendable, Equatable {
    public static let sampleRate = 16_000
    public let samples: [Int16]
    public let timestamp: TimeInterval
    public init(samples: [Int16], timestamp: TimeInterval) throws {
        guard timestamp.isFinite, timestamp >= 0 else { throw SttFailure.invalidAudio }
        self.samples = samples
        self.timestamp = timestamp
    }
    public var pcmData: Data {
        Data(samples.flatMap { sample in
            let bits = UInt16(bitPattern: sample)
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
        })
    }
    public var floats: [Float] { samples.map { Float($0) / 32768 } }
}

public enum SttFailure: String, Error, Sendable, Equatable {
    case invalidAudio, unavailable, transport, invalidResponse, timedOut, cancelled
}

/// Each partial replaces the current uncommitted segment; each final appends one stable segment.
/// Errors contain no provider payload, audio or transcript. End of input means end of utterance.
public enum SttEvent: Sendable, Equatable {
    /// Router emits this before any text; UI can show cloud processing.
    case selected(EngineDescriptor)
    case partial(String)
    case final(String)
    case failure(SttFailure)
}

public struct EngineDescriptor: Sendable, Equatable {
    public enum Location: Sendable { case onDevice, cloud }
    public let id: String
    public let version: String
    public let location: Location
    public var isCloud: Bool { location == .cloud }
    public init(id: String, version: String, location: Location) {
        self.id = id; self.version = version; self.location = location
    }
}

public protocol SttEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent>
}

public protocol CaptureSource: Sendable {
    func frames() -> AsyncStream<AudioFrame>
}

/// In-memory only; the caller owns private persistence and selects the authenticated user's list.
public struct Vocabulary: Sendable, Equatable {
    public let userID: String
    public let terms: [String]
    public init(userID: String, terms: [String]) {
        self.userID = userID
        var seen = Set<String>()
        self.terms = terms.compactMap {
            // Inspect original scalars before trimming; boundary CRLF must not disappear from validation.
            guard !$0.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            }) else { return nil }
            let term = $0.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }
}

public struct ScriptedCaptureSource: CaptureSource {
    public let script: [AudioFrame]
    public init(_ script: [AudioFrame]) { self.script = script }
    public func frames() -> AsyncStream<AudioFrame> {
        AsyncStream { continuation in
            for frame in script { continuation.yield(frame) }
            continuation.finish()
        }
    }
}

public struct FakeEngine: SttEngine {
    public let descriptor: EngineDescriptor
    public let script: [SttEvent]
    public init(id: String = "fake", script: [SttEvent], location: EngineDescriptor.Location = .onDevice) {
        descriptor = .init(id: id, version: "synthetic-1", location: location)
        self.script = script
    }
    public func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in audio { if Task.isCancelled { break } }
                if !Task.isCancelled { for event in script { continuation.yield(event) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
