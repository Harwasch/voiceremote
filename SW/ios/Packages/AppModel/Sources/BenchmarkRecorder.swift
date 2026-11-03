import Foundation
#if canImport(Darwin)
import Observation
#endif
import Stt
import Brain

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
    public var clippingAnnotation = "TBD"
    public var batteryEngineID = ""
    public var batteryCohortID = ""
    public var batteryDurationSeconds = ""
    public var batteryDrainPercentagePoints = ""
    public var batteryConditions = ""
    public private(set) var commandCases: [BrainBenchmarkCase] = []
    private var commandTranscripts: [String: String] = [:]
    private var commandRecordings: [String: String] = [:]
    public var isCommandRun: Bool { !commandCases.isEmpty }
    /// Import the reviewed 50-command set from Files; no normal commands are dispatched.
    public func loadCommands(_ data: Data) throws {
        guard !busy, completed == 0 else { throw SttFailure.unavailable }
        let cases = try BrainBenchmarkCase.load(data)
        guard Set(cases.map(\.id)).count == 50 else { throw SttFailure.invalidResponse }
        commandCases = cases
        prompts = cases.map { .init(id: $0.id, category: "normal", expectedText: $0.prompt) }
    }
    /// Build an in-memory playback container; never persist a second audio copy.
    public func lastRecordingWAV() throws -> Data {
        guard !busy, let url = audioURLs.last else { throw SttFailure.unavailable }
        let pcm = try Data(contentsOf: url)
        guard pcm.count <= Int(UInt32.max) - 36 else { throw SttFailure.invalidAudio }
        var wav = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
        number(UInt32(pcm.count + 36)); wav.append(Data("WAVEfmt ".utf8)); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(AudioFrame.sampleRate)); number(UInt32(AudioFrame.sampleRate * 2))
        number(UInt16(2)); number(UInt16(16)); wav.append(Data("data".utf8)); number(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }
    /// Acoustic listening judgement, independently of WER.
    public func annotateLastCapture() {
        guard !busy, let last = runs.indices.last else { return }
        let value: Bool?
        switch clippingAnnotation {
        case "TBD": value = nil
        case "Clipped": value = true
        case "Not clipped": value = false
        default: return
        }
        for engine in runs[last].engines.indices { runs[last].engines[engine].results[0].clipped_first_word = value }
    }
    public func prepareCommandExport(brain: any LlmBrain, engineID: String, engineVersion: String) async throws -> URL {
        guard !busy, isCommandRun, completed == 50, let first = runs.first else { throw SttFailure.unavailable }
        evaluatingCommands = true
        defer { evaluatingCommands = false }
        let url = directory.appendingPathComponent("brain-" + sessionID).appendingPathExtension("json")
        var speechRun = try BenchRun.aggregate(runs)
        guard !speechRun.engines.contains(where: { $0.id == engineID }) else { throw SttFailure.invalidResponse }
        let battery = try batterySample()
        if let battery, batteryEngineID != engineID {
            guard let engine = speechRun.engines.firstIndex(where: { $0.id == batteryEngineID }) else { throw SttFailure.invalidResponse }
            speechRun.engines[engine].battery = battery
        }
        try await BrainBenchmark.writeRun(brain: brain, cases: commandCases, accountID: "bench-account",
            engineID: engineID, engineVersion: engineVersion, device: first.device, sessionID: sessionID,
            synthetic: first.synthetic, captureSource: first.capture_source, outputURL: url,
            spokenTranscripts: commandTranscripts, recordingIDs: commandRecordings)
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let speech = try JSONSerialization.jsonObject(with: speechRun.json()) as? [String: Any],
              var engines = object["engines"] as? [[String: Any]], let speechEngines = speech["engines"] as? [[String: Any]] else { throw SttFailure.invalidResponse }
        if let battery, batteryEngineID == engineID { engines[0]["battery"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(battery)) }
        object["engines"] = speechEngines + engines; object["stt_cases"] = speech["stt_cases"]; object["vocabulary"] = speech["vocabulary"]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        exportURL = url; return url
    }
    private func batterySample() throws -> BenchRun.Battery? {
        if batteryEngineID.isEmpty && batteryCohortID.isEmpty && batteryDurationSeconds.isEmpty && batteryDrainPercentagePoints.isEmpty && batteryConditions.isEmpty { return nil }
        guard let duration = Double(batteryDurationSeconds), let drain = Double(batteryDrainPercentagePoints) else { throw SttFailure.invalidResponse }
        return try .init(cohortID: batteryCohortID, durationSeconds: duration, drainPercentagePoints: drain, conditions: batteryConditions)
    }
    public private(set) var exportURL: URL?
    public var busy: Bool { worker != nil || evaluatingCommands }
    private var evaluatingCommands = false
    public var lastCompletedCaseID: String? { runs.last?.stt_cases.first?.id }
    public var prompt: RecorderPrompt? { prompts.indices.contains(index) ? prompts[index] : nil }
    private let directory: URL
    private var sessionID = UUID().uuidString
    private let phrasePrompts: [RecorderPrompt]
    private var runs: [BenchRun] = []
    private var audioURLs: [URL] = []
    private var worker: Task<Void, Never>?
    private var capture: (any CaptureSession)?
    public init(prompts: [RecorderPrompt], directory: URL) throws {
        self.prompts = prompts; phrasePrompts = prompts; self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Clean abandoned recordings on launch unless user explicitly kept them.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "pcm" { try FileManager.default.removeItem(at: url) }
        try maintain()
    }
    /// Locally staged exports contain benchmark transcripts. Explicitly kept
    /// benchmark audio is a separate opt-in and is not part of default retention.
    public func maintain(now: Date = Date()) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            where url.pathExtension == "json" {
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if date == nil || date! > now || now.timeIntervalSince(date!) >= 604_800 {
                try FileManager.default.removeItem(at: url)
            }
        }
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
                if !runs.isEmpty { _ = try BenchRun.aggregate(runs + [run]) }
                if isCommandRun {
                    commandTranscripts[prompt.id] = run.engines[0].results[0].text
                    commandRecordings[prompt.id] = recordingID
                }
                clippingAnnotation = "TBD"
                runs.append(run); audioURLs.append(url); completed = runs.count; index += 1
            } catch {
                try? FileManager.default.removeItem(at: url)
                message = "Recording failed or was interrupted. Please repeat this prompt."
            }
            source.finish(); recording = false; capture = nil; worker = nil
        }
    }
    public var canStartNewCohort: Bool { !busy && completed > 0 && audioURLs.isEmpty }
    public func startNewCohort() throws {
        guard canStartNewCohort else { throw SttFailure.unavailable }
        runs = []; commandCases = []; commandTranscripts = [:]; commandRecordings = [:]
        prompts = phrasePrompts; index = 0; completed = 0; exportURL = nil; message = nil
        sessionID = UUID().uuidString; clippingAnnotation = "TBD"
        batteryEngineID = ""; batteryCohortID = ""; batteryDurationSeconds = ""
        batteryDrainPercentagePoints = ""; batteryConditions = ""
    }
    public func finish() { capture?.finish(); recording = false }
    public func cancel() { capture?.interrupt(); worker?.cancel() }
    /// Only the caller observing a correlated delivery/field confirmation supplies these offsets.
    /// A transport write or timeout is not field confirmation. No benchmark injection occurs here.
    public func annotateStages(caseID: String, engineID: String, stages: BenchRun.Stages) throws {
        guard !busy, let run = runs.firstIndex(where: { $0.stt_cases.contains(where: { $0.id == caseID }) }),
              let engine = runs[run].engines.firstIndex(where: { $0.id == engineID }),
              let result = runs[run].engines[engine].results.firstIndex(where: { $0.case_id == caseID }) else { throw SttFailure.invalidResponse }
        let measured = runs[run].engines[engine].results[result].stages
        func suppliedOrMeasured(_ supplied: Double?, _ measured: Double?) -> Double? {
            if let supplied { return supplied }; return measured
        }
        runs[run].engines[engine].results[result].stages = try .init(
            cleanupStartedMS: suppliedOrMeasured(stages.cleanup_started_ms, measured?.cleanup_started_ms),
            cleanupCompletedMS: suppliedOrMeasured(stages.cleanup_completed_ms, measured?.cleanup_completed_ms),
            deliveryStartedMS: stages.delivery_started_ms,
            deliveryCompletedMS: stages.delivery_completed_ms, fieldConfirmedMS: stages.field_confirmed_ms)
    }
    public func prepareExport() throws -> URL {
        guard !busy else { throw SttFailure.unavailable }
        guard !isCommandRun else { throw SttFailure.unavailable }
        var run = try BenchRun.aggregate(runs)
        if let battery = try batterySample() {
            guard let engine = run.engines.firstIndex(where: { $0.id == batteryEngineID }) else { throw SttFailure.invalidResponse }
            run.engines[engine].battery = battery
        }
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
