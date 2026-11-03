// Purpose: recorder metadata and 50-command integration. Inputs: synthetic PCM and reviewed fixture set.
// Verification: Linux package tests; no microphone, delivery or model performance claim.
import Foundation
import Testing
import Stt
import Brain
@testable import AppModel

@Test @MainActor func namedBoardBenchmarkExportsNeverClaimThePhoneMicrophone() async throws {
    for name in ["M5Stack StopWatch", "Waveshare ESP32-C6-Touch-LCD-1.69"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try BenchmarkRecorder(prompts: [.init(id: "fixture", category: "normal", expectedText: "Synthetic")], directory: directory)
        let source = Capture()
        recorder.start(source: source, first: FakeEngine(id: "a", script: [.final("Synthetic")]),
            second: FakeEngine(id: "b", script: [.final("Synthetic")]), vocabulary: .init(userID: "fixture", terms: []),
            device: "Linux synthetic decoder boundary", captureKind: .synthetic, cloudConsent: false, synthetic: true, namedSource: name)
        for _ in 0..<2000 { if source.starts > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        source.channel.continuation.yield(.frame(try AudioFrame(samples: [1], timestamp: 0))); recorder.finish()
        for _ in 0..<2000 { if !recorder.busy { break }; try await Task.sleep(for: .milliseconds(1)) }
        let value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.prepareExport())) as? [String: Any])
        #expect(value["source"] as? String == name)
        #expect(value["source_type"] as? String == "remote")
        #expect(value["format"] as? String == "voiceremote-named-source-benchmark-v1")
        #expect((value["comparison"] as? [String: Any])?["capture_source"] == nil)
    }
}

@Test @MainActor func recorderCarriesAnnotationsAndControlledBatteryWithoutInventingFieldConfirmation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try BenchmarkRecorder(prompts: [.init(id: "case", category: "normal", expectedText: "Synthetic")], directory: directory)
    let source = Capture()
    recorder.start(source: source, first: FakeEngine(id: "a", script: [.final("Synthetic")]),
        second: FakeEngine(id: "b", script: [.final("Synthetic")]), vocabulary: .init(userID: "fixture", terms: []),
        device: "Linux synthetic", captureKind: .synthetic, cloudConsent: false, synthetic: true)
    for _ in 0..<2000 { if source.starts > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
    source.channel.continuation.yield(.frame(try AudioFrame(samples: [1], timestamp: 0))); recorder.finish()
    for _ in 0..<2000 { if !recorder.busy { break }; try await Task.sleep(for: .milliseconds(1)) }
    #expect(recorder.completed == 1)
    recorder.clippingAnnotation = "Clipped"; recorder.annotateLastCapture()
    recorder.batteryEngineID = "a"; recorder.batteryCohortID = "controlled"
    recorder.batteryDurationSeconds = "600"; recorder.batteryDrainPercentagePoints = "2"
    recorder.batteryConditions = "Synthetic independent measurement fixture"
    let wav = try recorder.lastRecordingWAV()
    #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    #expect(wav.count == 46)
    let data = try Data(contentsOf: recorder.prepareExport())
    try BenchSchemaValidator.repositorySchema().validate(data)
    let run = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let engines = try #require(run["engines"] as? [[String: Any]])
    #expect(engines[0]["battery"] != nil); #expect(engines[1]["battery"] == nil)
    let result = try #require((engines[0]["results"] as? [[String: Any]])?.first)
    #expect(result["clipped_first_word"] as? Bool == true)
    #expect((result["stages"] as? [String: Any])?["field_confirmed_ms"] == nil)
    try recorder.annotateStages(caseID: "case", engineID: "a", stages: .init(
        deliveryStartedMS: 1_000_000, deliveryCompletedMS: 2_000_000, fieldConfirmedMS: 3_000_000))
    let annotated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.prepareExport())) as? [String: Any])
    let measured = try #require(((annotated["engines"] as? [[String: Any]])?.first?["results"] as? [[String: Any]])?.first?["stages"] as? [String: Any])
    #expect(measured["cleanup_completed_ms"] != nil)
    #expect(measured["field_confirmed_ms"] as? Double == 3_000_000)
    #expect(!recorder.canStartNewCohort)
    try recorder.exportCompleted(success: true)
    try recorder.startNewCohort()
    #expect(recorder.completed == 0)
    #expect(recorder.prompt?.id == "case")
}

@Test @MainActor func recorderRecordsAllFiftyCommandsAndNeverSubstitutesReadingPrompt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try BenchmarkRecorder(prompts: [], directory: directory)
    let sw = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try recorder.loadCommands(Data(contentsOf: sw.appendingPathComponent("bench/sets/commands.json")))
    #expect(recorder.prompts.count == 50)
    for _ in 0..<50 {
        let source = Capture()
        recorder.start(source: source, first: FakeEngine(id: "a", script: [.final("Synthetic recognized command")]),
            second: FakeEngine(id: "b", script: [.final("Second engine text")]), vocabulary: .init(userID: "fixture", terms: []),
            device: "Linux synthetic", captureKind: .synthetic, cloudConsent: false, synthetic: true)
        for _ in 0..<2000 { if source.starts > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        source.channel.continuation.yield(.frame(try AudioFrame(samples: [1], timestamp: 0))); recorder.finish()
        for _ in 0..<2000 { if !recorder.busy { break }; try await Task.sleep(for: .milliseconds(1)) }
    }
    #expect(recorder.completed == 50)
    actor ProposalOnly: LlmBrain {
        var transcripts: [String] = []
        func propose(_ request: BrainRequest) async throws -> BrainResponse { transcripts.append(request.transcript); return BrainResponse() }
    }
    let brain = ProposalOnly()
    let url = try await recorder.prepareCommandExport(brain: brain, engineID: "synthetic-brain", engineVersion: "fixture")
    #expect(await brain.transcripts.count == 50)
    #expect(await brain.transcripts.allSatisfy { $0 == "Synthetic recognized command" })
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect((root["brain_cases"] as? [Any])?.count == 50)
    #expect(recorder.exportURL == url)
    if let destination = ProcessInfo.processInfo.environment["RECORDER_SYNTHETIC_EXPORT_PATH"] {
        try Data(contentsOf: url).write(to: URL(fileURLWithPath: destination))
    }
}
