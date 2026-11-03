import Foundation
import VoiceRemoteProtocol

public struct BrainBenchmarkCase: Sendable {
    public let id: String
    public let prompt: String
    public let context: String
    public let expectedCalls: [BrainProposal]
    public init(id: String, prompt: String, context: String, expectedCalls: [BrainProposal]) {
        self.id = id; self.prompt = prompt; self.context = context; self.expectedCalls = expectedCalls
    }
}

/// SW/bench/schemas/run.schema.json v1. Caller chooses a private output path; no logging or execution.
public enum BrainBenchmark {
    public static func writeRun(brain: any LlmBrain, cases: [BrainBenchmarkCase], accountID: String,
                                engineID: String, engineVersion: String, device: String, sessionID: String,
                                synthetic: Bool, captureSource: String, outputURL: URL) async throws {
        guard validID(engineID), validID(sessionID), !engineVersion.isEmpty, !device.isEmpty,
              !cases.isEmpty, Set(cases.map(\.id)).count == cases.count,
              (synthetic ? ["synthetic", "iphone_mic", "airpods"] : ["iphone_mic", "airpods"]).contains(captureSource),
              cases.allSatisfy({ validID($0.id) && !$0.prompt.isEmpty && !$0.context.isEmpty && !$0.expectedCalls.isEmpty }) else {
            throw BrainError.invalidConfiguration
        }
        var results: [[String: Any]] = []
        for item in cases {
            let clock = ContinuousClock()
            let start = clock.now
            let response: BrainResponse
            do {
                response = try await brain.propose(BrainRequest(accountID: accountID, transcript: item.prompt, context: item.context))
            } catch is CancellationError { throw CancellationError() }
            catch { response = BrainResponse() }
            let elapsed = start.duration(to: clock.now).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            results.append(["case_id": item.id, "calls": try objects(response.proposals), "latency_ms": max(0, milliseconds)])
        }
        let exportedCases: [[String: Any]] = try cases.map {
            ["id": $0.id, "prompt": $0.prompt, "context": $0.context, "expected_calls": try objects($0.expectedCalls)]
        }
        let run: [String: Any] = [
            "schema_version": 1, "synthetic": synthetic, "device": device, "capture_source": captureSource,
            "session_id": sessionID, "vocabulary": [String](), "stt_cases": [String](), "brain_cases": exportedCases,
            "engines": [["id": engineID, "kind": "brain", "version": engineVersion, "results": results]]
        ]
        try JSONSerialization.data(withJSONObject: run, options: [.sortedKeys, .prettyPrinted]).write(to: outputURL, options: .atomic)
    }

    private static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"#, options: .regularExpression) != nil
            && !id.contains("\n")
    }

    private static func objects(_ proposals: [BrainProposal]) throws -> [Any] {
        try proposals.map { try JSONSerialization.jsonObject(with: VoiceRemoteProtocol.ProtocolCodec.encode($0.tool)) }
    }
}
