import Foundation
import XCTest
@testable import Stt

private actor AudioRecorder {
    var frames: [AudioFrame] = []
    var terms: [String] = []
    func record(_ frame: AudioFrame) { frames.append(frame) }
    func vocabulary(_ vocabulary: Vocabulary) { terms = vocabulary.terms }
}
private struct RecordingEngine: SttEngine {
    let descriptor: EngineDescriptor
    let recorder: AudioRecorder
    func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
        AsyncStream { out in
            let task = Task {
                await recorder.vocabulary(vocabulary)
                for await frame in audio { await recorder.record(frame); out.yield(.partial("synthetic")) }
                out.yield(.final("Synthetic phrase.")); out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }
}
@MainActor final class ABRunnerTests: XCTestCase {
    func testIdenticalPCMAndVocabularyAndExportValidatesAgainstBenchSchema() async throws {
        let frames = try [AudioFrame(samples: [-32768, 0, 32767], timestamp: 0), AudioFrame(samples: [0, 1], timestamp: 0.01)]
        let a = AudioRecorder(); let b = AudioRecorder()
        let run = try await ABRunner().run(
            RecordingEngine(descriptor: .init(id: "a", version: "synthetic-1", location: .onDevice), recorder: a),
            RecordingEngine(descriptor: .init(id: "b", version: "synthetic-1", location: .cloud), recorder: b),
            source: ScriptedCaptureSource(frames), vocabulary: .init(userID: "fake", terms: ["Codex"]),
            testCase: .init(id: "case-1", category: .normal, expectedText: "Synthetic phrase.", recordingID: "fake-audio"),
            sessionID: "synthetic-test", device: "Linux synthetic test; no phone measurements", capture: .synthetic, synthetic: true, cloudConsent: true)
        let receivedA = await a.frames; let receivedB = await b.frames; let terms = await b.terms
        XCTAssertEqual(receivedA, frames); XCTAssertEqual(receivedB, frames); XCTAssertEqual(terms, ["Codex"])
        XCTAssertEqual(run.engines.map { $0.results[0].text }, ["Synthetic phrase.", "Synthetic phrase."])
        try BenchSchemaValidator.repositorySchema().validate(run.json())
    }
    func testFailedAndTimedOutEnginesExportEmptyTextNotPartial() async throws {
        let never = AsyncStream<AudioFrame>.makeStream()
        struct HangingSource: CaptureSource {
            let stream: AsyncStream<AudioFrame>
            func frames() -> AsyncStream<AudioFrame> { stream }
        }
        let result = try await ABRunner().run(FakeEngine(id: "a", script: [.partial("partial only")]),
            FakeEngine(id: "b", script: [.failure(.transport)]), source: HangingSource(stream: never.stream),
            vocabulary: .init(userID: "test", terms: []),
            testCase: .init(id: "case", category: .normal, expectedText: "Synthetic", recordingID: "fake"),
            sessionID: "test", device: "synthetic Linux", capture: .synthetic, synthetic: true, timeout: .milliseconds(10))
        never.continuation.finish()
        XCTAssertEqual(result.engines.map { $0.results[0].text }, ["", ""])
    }
    func testPCMEncodingAndTimestampValidation() async throws {
        XCTAssertThrowsError(try AudioFrame(samples: [], timestamp: .nan))
        XCTAssertThrowsError(try AudioFrame(samples: [], timestamp: -1))
        let frame = try AudioFrame(samples: [-32768, -1, 0, 32767], timestamp: 0)
        XCTAssertEqual(Array(frame.pcmData), [0, 128, 255, 255, 0, 0, 255, 127])
        XCTAssertEqual(frame.floats.first, -1)
    }
    func testPublicAggregationProducesTwoHundredCaseBenchRunAndRejectsMixedCohorts() async throws {
        let runs = try (0..<200).map { index in
            try BenchRun(synthetic: true, device: "synthetic Linux", captureSource: "synthetic", sessionID: "cohort",
                vocabulary: ["Codex"], sttCases: [.init(id: "case-\(index)", category: .normal, expectedText: "Synthetic", recordingID: "fixture-\(index)")],
                engines: [BenchRun.Engine(id: "a", version: "test", results: [.init(caseID: "case-\(index)", text: "Synthetic", firstTextMS: 1, finalAfterEOSMS: 2)]),
                          BenchRun.Engine(id: "b", version: "test", results: [.init(caseID: "case-\(index)", text: "Synthetic", firstTextMS: 3, finalAfterEOSMS: 4)])])
        }
        let combined = try BenchRun.aggregate(runs)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("stt-synthetic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try combined.write(to: destination)
        try BenchSchemaValidator.repositorySchema().validate(Data(contentsOf: destination))
        XCTAssertEqual(combined.stt_cases.count, 200)
        XCTAssertEqual(combined.engines.map { $0.results.count }, [200, 200])
        XCTAssertThrowsError(try combined.merging(runs[0]))
        XCTAssertThrowsError(try BenchRun.aggregate([]))
        let other = try BenchRun(synthetic: true, device: "different", captureSource: "synthetic", sessionID: "cohort",
            vocabulary: ["Codex"], sttCases: runs[0].stt_cases, engines: runs[0].engines)
        XCTAssertThrowsError(try runs[1].merging(other))
        XCTAssertThrowsError(try BenchRun(synthetic: true, device: "test", captureSource: "synthetic", sessionID: "cohort",
            vocabulary: [], sttCases: runs[0].stt_cases,
            engines: [.init(id: "a", version: "test", results: [.init(caseID: "unknown", text: "Synthetic")])]))
    }
    func testRunnerRecordsMonotonicFirstTextAndFinalAfterEOS() async throws {
        struct TimedEngine: SttEngine {
            let descriptor: EngineDescriptor
            func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
                AsyncStream { out in
                    let task = Task {
                        for await _ in audio {}
                        try? await Task.sleep(for: .milliseconds(20)); out.yield(.partial("Synthetic"))
                        try? await Task.sleep(for: .milliseconds(20)); out.yield(.final("Synthetic.")); out.finish()
                    }
                    out.onTermination = { _ in task.cancel() }
                }
            }
        }
        let run = try await ABRunner().run(
            TimedEngine(descriptor: .init(id: "a", version: "test", location: .onDevice)),
            TimedEngine(descriptor: .init(id: "b", version: "test", location: .onDevice)),
            source: ScriptedCaptureSource([try AudioFrame(samples: [0], timestamp: 0)]), vocabulary: .init(userID: "test", terms: []),
            testCase: .init(id: "case", category: .normal, expectedText: "Synthetic.", recordingID: "fixture"),
            sessionID: "test", device: "synthetic Linux", capture: .synthetic, synthetic: true)
        for engine in run.engines {
            let result = engine.results[0]
            XCTAssertGreaterThan(try XCTUnwrap(result.first_text_ms), 10)
            XCTAssertGreaterThan(try XCTUnwrap(result.final_after_eos_ms), 30)
        }
    }

    func testABCloudRequiresExplicitConsentBeforeConsumingAudio() async throws {
        let recorder = AudioRecorder()
        do {
            _ = try await ABRunner().run(FakeEngine(id: "a", script: [.final("Synthetic")]),
                RecordingEngine(descriptor: .init(id: "b", version: "test", location: .cloud), recorder: recorder),
                source: ScriptedCaptureSource([try AudioFrame(samples: [0], timestamp: 0)]), vocabulary: .init(userID: "test", terms: []),
                testCase: .init(id: "case", category: .normal, expectedText: "Synthetic", recordingID: "fake"),
                sessionID: "test", device: "synthetic Linux", capture: .synthetic, synthetic: true)
            XCTFail("Cloud A/B requires consent")
        } catch { XCTAssertEqual(error as? SttFailure, .invalidResponse) }
        let frames = await recorder.frames; XCTAssertEqual(frames, [])
    }
    func testOfflineSchemaValidatorRejectsInvalidContractWithoutExternalTools() async throws {
        let validator = try BenchSchemaValidator.repositorySchema()
        let valid: [String: Any] = ["schema_version": 1, "synthetic": true, "device": "test", "capture_source": "synthetic",
            "session_id": "test", "vocabulary": [], "stt_cases": [["id": "case", "category": "normal", "expected_text": "Synthetic", "recording_id": "fake"]],
            "brain_cases": [], "engines": [["id": "a", "kind": "stt", "version": "test", "results": [["case_id": "case", "text": "Synthetic", "first_text_ms": 1.0]]]]]
        try validator.validate(JSONSerialization.data(withJSONObject: valid))
        for (key, bad): (String, Any) in [("schema_version", 2), ("schema_version", true), ("synthetic", false), ("device", ""),
                                         ("session_id", "invalid id"), ("vocabulary", ["same", "same"]), ("extra", "forbidden")] {
            var invalid = valid; invalid[key] = bad
            XCTAssertThrowsError(try validator.validate(JSONSerialization.data(withJSONObject: invalid)), key)
        }
        var invalid = valid
        invalid["engines"] = [["id": "a", "kind": "stt", "version": "test", "results": [["case_id": "case", "text": "Synthetic", "first_text_ms": -1]]]]
        XCTAssertThrowsError(try validator.validate(JSONSerialization.data(withJSONObject: invalid)))
    }

}
