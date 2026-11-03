import Foundation
import Testing
@testable import Stt

private struct LostSource: CaptureSource {
    func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<CaptureEvent> {
        AsyncStream { output in
            output.yield(.frame(try! AudioFrame(samples: [0], timestamp: 0)))
            output.yield(.interrupted)
            // Trailing frames are never reinterpreted as a complete utterance.
            output.yield(.frame(try! AudioFrame(samples: [1], timestamp: 1)))
            output.finish()
        }
    }
}
@Test func captureInterruptionIsTerminalEvenOfflineAndDiscardsStableFinals() async {
    for online in [false, true] {
        var events: [SttEvent] = []
        let engine = FakeEngine(script: [.final("invented pending command")])
        for await event in EngineRouter().transcribe(source: LostSource(), engines: [engine],
            conditions: .init(online: online), vocabulary: .init(userID: "fixture", terms: [])) { events.append(event) }
        #expect(events.contains(.failure(.interrupted)))
        #expect(!events.contains { if case .final = $0 { return true }; return false })
    }
}
@Test func interruptedABRunCannotExportApparentlySuccessfulResults() async throws {
    do {
        _ = try await ABRunner().run(FakeEngine(id: "one", script: [.final("invented")]),
            FakeEngine(id: "two", script: [.final("invented")]), source: LostSource(),
            vocabulary: .init(userID: "fixture", terms: []),
            testCase: .init(id: "fixture", category: .normal, expectedText: "invented", recordingID: "fixture"),
            sessionID: "fixture", device: "Linux synthetic", capture: .synthetic, synthetic: true)
        Issue.record("Interrupted audio exported a run")
    } catch { #expect(error as? SttFailure == .interrupted) }
}

@Test func engineReportedInterruptionCannotCommitEarlierFinals() async {
    for online in [true, false] {
        var result: [SttEvent] = []
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]),
            engines: [FakeEngine(script: [.final("invented pending"), .failure(.interrupted)])],
            conditions: .init(online: online), vocabulary: .init(userID: "fixture", terms: [])) { result.append(event) }
        #expect(result.contains(.failure(.interrupted)))
        #expect(!result.contains { if case .final = $0 { true } else { false } })
    }
}
