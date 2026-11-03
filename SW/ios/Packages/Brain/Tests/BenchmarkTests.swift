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

    func testRealCaptureCannotBeMislabelledSynthetic() async throws {
        do {
            try await BrainBenchmark.writeRun(brain: TestBrain(), cases: [], accountID: "a", engineID: "test",
                engineVersion: "test", device: "fictional", sessionID: "test", synthetic: false,
                captureSource: "synthetic", outputURL: URL(fileURLWithPath: "/unused"))
            XCTFail("Invalid run accepted")
        } catch { XCTAssertEqual(error as? BrainError, .invalidConfiguration) }
    }
}
