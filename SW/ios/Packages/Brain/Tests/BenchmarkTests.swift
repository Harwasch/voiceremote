import XCTest
import Foundation
@testable import Brain

final class BenchmarkTests: XCTestCase, @unchecked Sendable {
    func testSyntheticBenchmarkWritesRunFormatAndFailedEngineHasEmptyCalls() async throws {
        let explicitPath = ProcessInfo.processInfo.environment["BRAIN_BENCH_EXPORT_PATH"]
        let url = explicitPath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("brain-synthetic-\(UUID()).json")
        defer { if explicitPath == nil { try? FileManager.default.removeItem(at: url) } }
        let cases = [BrainBenchmarkCase(id: "route-one", prompt: "select laptop", context: "Fictional device laptop",
                                        expectedCalls: [proposal()])]
        try await BrainBenchmark.writeRun(brain: TestBrain(failure: .unavailable), cases: cases, accountID: "a",
            engineID: "synthetic-brain", engineVersion: "test-only", device: "Linux synthetic fixture",
            sessionID: "synthetic-session", synthetic: true, captureSource: "synthetic", outputURL: url)
        let run = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(run["schema_version"] as? Int, 1); XCTAssertEqual(run["synthetic"] as? Bool, true)
        XCTAssertEqual(Set(run.keys), ["schema_version", "synthetic", "device", "capture_source", "session_id",
                                       "vocabulary", "stt_cases", "brain_cases", "engines"])
        let engines = try XCTUnwrap(run["engines"] as? [[String: Any]])
        XCTAssertEqual(engines[0]["kind"] as? String, "brain")
        let results = try XCTUnwrap(engines[0]["results"] as? [[String: Any]])
        XCTAssertEqual((results[0]["calls"] as? [Any])?.count, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(results[0]["latency_ms"] as? Double), 0)
    }

    func testFiftySpokenCommandsUseRecognizedTextNotExpectedPrompt() async throws {
        actor RecordingBrain: LlmBrain {
            var transcripts: [String] = []
            func propose(_ request: BrainRequest) async throws -> BrainResponse {
                transcripts.append(request.transcript); return BrainResponse()
            }
        }
        let brain = RecordingBrain()
        let cases = (0..<50).map { BrainBenchmarkCase(id: "cmd-\($0)", prompt: "Expected fictional command", context: "Fictional context", expectedCalls: [proposal()]) }
        let transcripts = Dictionary(uniqueKeysWithValues: cases.enumerated().map { ($0.element.id, "Recognized synthetic \($0.offset)") })
        let ids = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, "recording-" + $0.id) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try await BrainBenchmark.writeRun(brain: brain, cases: cases, accountID: "a", engineID: "fake", engineVersion: "test",
            device: "synthetic", sessionID: "session", synthetic: false, captureSource: "iphone_mic", outputURL: url,
            spokenTranscripts: transcripts, recordingIDs: ids)
        let received = await brain.transcripts
        XCTAssertEqual(received.count, 50)
        XCTAssertEqual(received.first, "Recognized synthetic 0")
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((data["brain_cases"] as? [[String: Any]])?.count, 50)
    }

    func testMissingSpokenRecognitionHasNoInventedBrainLatencyOrCalls() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try await BrainBenchmark.writeRun(brain: TestBrain(),
            cases: [.init(id: "missing", prompt: "Expected fictional command", context: "Fictional context", expectedCalls: [proposal()])],
            accountID: "a", engineID: "fake", engineVersion: "fixture", device: "Linux synthetic", sessionID: "session",
            synthetic: true, captureSource: "synthetic", outputURL: url,
            spokenTranscripts: ["missing": ""], recordingIDs: ["missing": "synthetic-recording"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let engine = try XCTUnwrap((root["engines"] as? [[String: Any]])?.first)
        let result = try XCTUnwrap((engine["results"] as? [[String: Any]])?.first)
        XCTAssertNil(result["latency_ms"])
        XCTAssertEqual((result["calls"] as? [Any])?.count, 0)
    }

    func testRealCaptureCannotBeMislabelledSynthetic() async throws {
        do {
            try await BrainBenchmark.writeRun(brain: TestBrain(), cases: [], accountID: "a", engineID: "test",
                engineVersion: "test", device: "fictional", sessionID: "test", synthetic: false,
                captureSource: "synthetic", outputURL: URL(fileURLWithPath: "/unused"))
            XCTFail("Invalid run accepted")
        } catch { XCTAssertEqual(error as? BrainError, .invalidConfiguration) }
    }
}
