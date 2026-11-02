import Foundation

/// Mirrors SW/bench/schemas/run.schema.json v1. Combine cases only within one recording cohort.
public struct BenchRun: Encodable, Sendable {
    public let schema_version = 1
    public let synthetic: Bool
    public let device: String
    public let capture_source: String
    public let session_id: String
    public let vocabulary: [String]
    public let stt_cases: [Case]
    public let brain_cases: [String] = []
    public let engines: [Engine]
    public struct Case: Encodable, Sendable {
        public enum Category: String, Encodable, Sendable { case normal, whispering, names, numbers, tech_terms }
        public let id: String
        public let category: Category
        public let expected_text: String
        public let recording_id: String
        public init(id: String, category: Category, expectedText: String, recordingID: String) {
            self.id = id; self.category = category; expected_text = expectedText; recording_id = recordingID
        }
    }
    public struct Engine: Encodable, Sendable {
        public let id: String
        public let kind = "stt"
        public let version: String
        public let results: [Result]
        public init(id: String, version: String, results: [Result]) {
            self.id = id; self.version = version; self.results = results
        }
    }
    public struct Result: Encodable, Sendable {
        public let case_id: String
        public let text: String
        public let first_text_ms: Double?
        public let final_after_eos_ms: Double?
        public init(caseID: String, text: String, firstTextMS: Double? = nil, finalAfterEOSMS: Double? = nil) {
            case_id = caseID; self.text = text
            first_text_ms = firstTextMS; final_after_eos_ms = finalAfterEOSMS
        }
    }
    /// Validates schema constraints plus scorer completeness/uniqueness before creating an export.
    public init(synthetic: Bool, device: String, captureSource: String, sessionID: String,
                vocabulary: [String], sttCases: [Case], engines: [Engine]) throws {
        let ids = Set(sttCases.map(\.id))
        guard !device.isEmpty, Self.validID(sessionID),
              ["iphone_mic", "airpods", "synthetic"].contains(captureSource), synthetic || captureSource != "synthetic",
              Set(vocabulary).count == vocabulary.count, vocabulary.allSatisfy({ !$0.isEmpty }),
              !sttCases.isEmpty, ids.count == sttCases.count,
              sttCases.allSatisfy({ Self.validID($0.id) && !$0.expected_text.isEmpty && !$0.recording_id.isEmpty }),
              !engines.isEmpty, Set(engines.map(\.id)).count == engines.count,
              engines.allSatisfy({ engine in
                  Self.validID(engine.id) && !engine.version.isEmpty &&
                  engine.results.count == ids.count && Set(engine.results.map(\.case_id)) == ids &&
                  engine.results.allSatisfy { result in
                      [result.first_text_ms, result.final_after_eos_ms].allSatisfy { value in
                          value.map { $0.isFinite && $0 >= 0 } ?? true
                      }
                  }
              }) else { throw SttFailure.invalidResponse }
        self.synthetic = synthetic; self.device = device; capture_source = captureSource
        session_id = sessionID; self.vocabulary = vocabulary; stt_cases = sttCases; self.engines = engines
    }
    public func merging(_ other: BenchRun) throws -> BenchRun {
        guard synthetic == other.synthetic, device == other.device, capture_source == other.capture_source,
              session_id == other.session_id, vocabulary == other.vocabulary,
              Set(engines.map(\.id)) == Set(other.engines.map(\.id)),
              Set(stt_cases.map(\.id)).isDisjoint(with: other.stt_cases.map(\.id)) else { throw SttFailure.invalidResponse }
        let merged = try engines.map { engine -> Engine in
            guard let next = other.engines.first(where: { $0.id == engine.id }), next.version == engine.version else {
                throw SttFailure.invalidResponse
            }
            return Engine(id: engine.id, version: engine.version, results: engine.results + next.results)
        }
        return try BenchRun(synthetic: synthetic, device: device, captureSource: capture_source, sessionID: session_id,
                            vocabulary: vocabulary, sttCases: stt_cases + other.stt_cases, engines: merged)
    }
    public static func aggregate(_ runs: [BenchRun]) throws -> BenchRun {
        guard let first = runs.first else { throw SttFailure.invalidResponse }
        return try runs.dropFirst().reduce(first) { try $0.merging($1) }
    }
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    /// Explicit private destination only. No automatic transcript/audio persistence or logging.
    public func write(to destination: URL) throws { try json().write(to: destination, options: .atomic) }
}

public struct ABRunner: Sendable {
    public enum Capture: String, Sendable { case iphone_mic, airpods, synthetic }
    public init() {}
    public func run(_ first: any SttEngine, _ second: any SttEngine, source: any CaptureSource,
                    vocabulary: Vocabulary, testCase: BenchRun.Case, sessionID: String,
                    device: String, capture: Capture, synthetic: Bool,
                    timeout: Duration = .seconds(60), cloudConsent: Bool = false) async throws -> BenchRun {
        guard BenchRun.validID(sessionID), BenchRun.validID(testCase.id), BenchRun.validID(first.descriptor.id),
              BenchRun.validID(second.descriptor.id), first.descriptor.id != second.descriptor.id,
              !device.isEmpty, !testCase.expected_text.isEmpty, !testCase.recording_id.isEmpty,
              !first.descriptor.version.isEmpty, !second.descriptor.version.isEmpty,
              synthetic || capture != .synthetic,
              cloudConsent || (!first.descriptor.isCloud && !second.descriptor.isCloud) else { throw SttFailure.invalidResponse }
        let timing = CaptureTiming()
        // Independent streams: sharing one AsyncStream iterator would divide, not duplicate, audio.
        let a = AsyncStream<AudioFrame>.makeStream()
        let b = AsyncStream<AudioFrame>.makeStream()
        async let resultA = collect(first.transcribe(a.stream, vocabulary: vocabulary), timeout: timeout)
        async let resultB = collect(second.transcribe(b.stream, vocabulary: vocabulary), timeout: timeout)
        let fanout = Task {
            for await frame in source.frames() {
                if Task.isCancelled { break }
                await timing.start()
                a.continuation.yield(frame); b.continuation.yield(frame)
            }
            await timing.end()
            a.continuation.finish(); b.continuation.finish()
        }
        defer { fanout.cancel(); a.continuation.finish(); b.continuation.finish() }
        let outputs = await (resultA, resultB)
        let origins = await timing.origins()
        func result(_ output: Collected) -> BenchRun.Result {
            func milliseconds(_ start: ContinuousClock.Instant?, _ end: ContinuousClock.Instant?) -> Double? {
                guard let start, let end else { return nil }
                let duration = start.duration(to: end).components
                return max(0, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            }
            return .init(caseID: testCase.id, text: output.text,
                         firstTextMS: milliseconds(origins.start, output.firstText),
                         finalAfterEOSMS: milliseconds(origins.end, output.final))
        }
        return try BenchRun(synthetic: synthetic, device: device, captureSource: capture.rawValue,
                            sessionID: sessionID, vocabulary: vocabulary.terms, sttCases: [testCase],
                            engines: [.init(id: first.descriptor.id, version: first.descriptor.version, results: [result(outputs.0)]),
                                      .init(id: second.descriptor.id, version: second.descriptor.version, results: [result(outputs.1)])])
    }
    private struct Collected: Sendable {
        let text: String
        let firstText: ContinuousClock.Instant?
        let final: ContinuousClock.Instant?
        static let failed = Collected(text: "", firstText: nil, final: nil)
    }
    private func collect(_ events: AsyncStream<SttEvent>, timeout: Duration) async -> Collected {
        let race = AsyncStream<Collected>.makeStream()
        let worker = Task {
            var finals: [String] = []
            var firstText: ContinuousClock.Instant?
            var final: ContinuousClock.Instant?
            for await event in events {
                switch event {
                case .final(let text):
                    let now = ContinuousClock.now
                    if firstText == nil && !text.isEmpty { firstText = now }
                    final = now; finals.append(text)
                case .failure: race.continuation.yield(.failed); race.continuation.finish(); return
                case .partial(let text):
                    if firstText == nil && !text.isEmpty { firstText = ContinuousClock.now }
                case .selected: break
                }
            }
            race.continuation.yield(Collected(text: finals.joined(separator: " "), firstText: firstText, final: final))
            race.continuation.finish()
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            race.continuation.yield(.failed); race.continuation.finish()
        }
        defer { worker.cancel(); timer.cancel(); race.continuation.finish() }
        var iterator = race.stream.makeAsyncIterator()
        return await iterator.next() ?? .failed
    }
}

private actor CaptureTiming {
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    func start() { if first == nil { first = ContinuousClock.now } }
    func end() { last = ContinuousClock.now }
    func origins() -> (start: ContinuousClock.Instant?, end: ContinuousClock.Instant?) { (first, last) }
}
