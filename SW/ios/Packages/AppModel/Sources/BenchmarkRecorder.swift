import Foundation
#if canImport(Darwin)
import Observation
#endif
import Stt

public struct RecorderPrompt: Decodable, Identifiable, Sendable {
    public let id: String
    public let category: String
    public let expected_text: String
    public init(id: String, category: String, expectedText: String) {
        self.id = id; self.category = category; expected_text = expectedText
    }
    public static func load(_ data: Data) throws -> [Self] {
        struct Set: Decodable { let phrases: [RecorderPrompt] }
        return try JSONDecoder().decode(Set.self, from: data).phrases
    }
}
/// The only audio persistence boundary. An explicit private recorder directory is mandatory.
/// A/B receives the same PCM. Normal dictation has no reference to this store.
#if canImport(Darwin)
@Observable
#endif
@MainActor public final class BenchmarkRecorder {
    public private(set) var prompts: [RecorderPrompt]
    public private(set) var index = 0
    public private(set) var recording = false
    public private(set) var completed = 0
    public private(set) var message: String?
    public var keepAudio = false
    public private(set) var exportURL: URL?
    public var busy: Bool { worker != nil }
    public var prompt: RecorderPrompt? { prompts.indices.contains(index) ? prompts[index] : nil }
    private let directory: URL
    private let sessionID = UUID().uuidString
    private var runs: [BenchRun] = []
    private var audioURLs: [URL] = []
    private var worker: Task<Void, Never>?
    private var capture: (any CaptureSession)?
    public init(prompts: [RecorderPrompt], directory: URL) throws {
        self.prompts = prompts; self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Clean abandoned recordings on launch unless user explicitly kept them.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "pcm" { try FileManager.default.removeItem(at: url) }
    }
    public func start(source: any CaptureSession, first: any SttEngine, second: any SttEngine,
                      vocabulary: Vocabulary, device: String, captureKind: ABRunner.Capture,
                      cloudConsent: Bool, synthetic: Bool = false,
                      actualCaptureKind: (@MainActor () -> ABRunner.Capture)? = nil) {
        guard !recording, let prompt, worker == nil,
              let category = BenchRun.Case.Category(rawValue: prompt.category) else { return }
        recording = true; message = nil; capture = source
        let recordingID = UUID().uuidString
        let url = directory.appendingPathComponent(recordingID).appendingPathExtension("pcm")
        worker = Task {
            do {
                try source.start()
                let resolvedCaptureKind = actualCaptureKind?() ?? captureKind
                let stored = RecorderCapture(source: source, url: url)
                let run = try await ABRunner().run(first, second, source: stored, vocabulary: vocabulary,
                    testCase: .init(id: prompt.id, category: category, expectedText: prompt.expected_text, recordingID: recordingID),
                    sessionID: sessionID, device: device, capture: resolvedCaptureKind, synthetic: synthetic,
                    timeout: .seconds(120), cloudConsent: cloudConsent)
                try Task.checkCancellation()
                if stored.failed { throw SttFailure.invalidAudio }
                runs.append(run); audioURLs.append(url); completed = runs.count; index += 1
            } catch {
                try? FileManager.default.removeItem(at: url)
                message = "Recording failed or was interrupted. Please repeat this prompt."
            }
            source.finish(); recording = false; capture = nil; worker = nil
        }
    }
    public func finish() { capture?.finish(); recording = false }
    public func cancel() { capture?.interrupt(); worker?.cancel() }
    public func prepareExport() throws -> URL {
        guard worker == nil else { throw SttFailure.unavailable }
        let run = try BenchRun.aggregate(runs)
        let url = directory.appendingPathComponent("bench-" + sessionID).appendingPathExtension("json")
        try run.write(to: url); exportURL = url; return url
    }
    /// Called by share-sheet completion, only after a successful export.
    public func exportCompleted(success: Bool) throws {
        guard success else { return }
        for url in audioURLs {
            if keepAudio { try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("kept")) }
            else { try FileManager.default.removeItem(at: url) }
        }
        audioURLs = []
    }
}

private final class RecorderCapture: CaptureSource, @unchecked Sendable {
    private let source: any CaptureSource
    private let url: URL
    private let lock = NSLock()
    private var didFail = false
    var failed: Bool { lock.withLock { didFail } }
    init(source: any CaptureSource, url: URL) { self.source = source; self.url = url }
    func frames() -> AsyncStream<AudioFrame> {
        AsyncStream { $0.finish() } // Recorder consumers must preserve interruption events.
    }
    func events() -> AsyncStream<CaptureEvent> {
        AsyncStream { output in
            let task = Task {
                do {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw SttFailure.invalidAudio
                    }
                    let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
                    for await event in source.events() {
                        try Task.checkCancellation()
                        if case .frame(let frame) = event { try file.write(contentsOf: frame.pcmData) }
                        output.yield(event)
                        if case .interrupted = event { break }
                    }
                } catch { lock.withLock { didFail = true }; output.yield(.interrupted) }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}
