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
    public static func load(_ data: Data, accountID: String = "bench-account") throws -> [Self] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let rows = root?["commands"] as? [[String: Any]], rows.count == 50,
              Set(rows.compactMap { $0["id"] as? String }).count == 50 else { throw BrainError.invalidConfiguration }
        return try rows.map { row in
            guard let id = row["id"] as? String, !id.isEmpty, let prompt = row["prompt"] as? String,
                  let context = row["context"] as? String, let calls = row["expected_calls"] as? [Any] else { throw BrainError.invalidConfiguration }
            let decoded = ProposalDecoder.decode(try JSONSerialization.data(withJSONObject: calls), accountID: accountID)
            guard decoded.droppedCount == 0, !decoded.proposals.isEmpty else { throw BrainError.invalidConfiguration }
            return Self(id: id, prompt: prompt, context: context, expectedCalls: decoded.proposals)
        }
    }

}

/// SW/bench/schemas/run.schema.json v1. Caller chooses a private output path; no logging or execution.
public enum BrainBenchmark {
    public static func writeRun(brain: any LlmBrain, cases: [BrainBenchmarkCase], accountID: String,
                                engineID: String, engineVersion: String, device: String, sessionID: String,
                                synthetic: Bool, captureSource: String, outputURL: URL,
                                spokenTranscripts: [String: String]? = nil, recordingIDs: [String: String]? = nil) async throws {
        guard validID(engineID), validID(sessionID), !engineVersion.isEmpty, !device.isEmpty,
              !cases.isEmpty, Set(cases.map(\.id)).count == cases.count,
              (synthetic ? ["synthetic", "iphone_mic", "airpods"] : ["iphone_mic", "airpods"]).contains(captureSource),
              cases.allSatisfy({ validID($0.id) && !$0.prompt.isEmpty && !$0.context.isEmpty && !$0.expectedCalls.isEmpty }) else {
            throw BrainError.invalidConfiguration
        }
        if let spokenTranscripts {
            guard Set(spokenTranscripts.keys) == Set(cases.map(\.id)),
                  let recordingIDs, Set(recordingIDs.keys) == Set(cases.map(\.id)),
                  recordingIDs.values.allSatisfy({ !$0.isEmpty }) else { throw BrainError.invalidConfiguration }
        } else if !synthetic { throw BrainError.invalidConfiguration }
        var results: [[String: Any]] = []
        for item in cases {
            let clock = ContinuousClock()
            let start = clock.now
            let response: BrainResponse
            let transcript = spokenTranscripts?[item.id] ?? item.prompt
            do {
                response = transcript.isEmpty ? BrainResponse() : try await brain.propose(BrainRequest(accountID: accountID, transcript: transcript, context: item.context))
            } catch is CancellationError { throw CancellationError() }
            catch { response = BrainResponse() }
            let elapsed = start.duration(to: clock.now).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            var result: [String: Any] = ["case_id": item.id, "calls": try objects(response.proposals)]
            if !transcript.isEmpty { result["latency_ms"] = max(0, milliseconds) }
            if let spokenTranscripts { result["transcript"] = spokenTranscripts[item.id] }
            results.append(result)
        }
        let exportedCases: [[String: Any]] = try cases.map {
            var row: [String: Any] = ["id": $0.id, "prompt": $0.prompt, "context": $0.context, "expected_calls": try objects($0.expectedCalls)]
            if let id = recordingIDs?[$0.id] { row["recording_id"] = id }
            return row
        }
        let run: [String: Any] = [
            "schema_version": 1, "synthetic": synthetic, "device": device, "capture_source": captureSource,
            "session_id": sessionID, "vocabulary": [String](), "stt_cases": [String](), "brain_cases": exportedCases,
            "engines": [["id": engineID, "kind": "brain", "version": engineVersion, "results": results]]
        ]
        try JSONSerialization.data(withJSONObject: run, options: [.sortedKeys, .prettyPrinted]).write(to: outputURL, options: .atomic)
    }

    private static func validID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars.map(\.value)
        func alphaNumeric(_ value: UInt32) -> Bool {
            (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
        }
        return (1...128).contains(scalars.count) && scalars.first.map(alphaNumeric) == true &&
            scalars.dropFirst().allSatisfy { alphaNumeric($0) || [95, 46, 58, 45].contains($0) }
    }

    private static func objects(_ proposals: [BrainProposal]) throws -> [Any] {
        try proposals.map { try JSONSerialization.jsonObject(with: VoiceRemoteProtocol.ProtocolCodec.encode($0.tool)) }
    }
}
