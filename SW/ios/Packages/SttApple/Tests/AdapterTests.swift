import XCTest
import Stt
@testable import SttApple

@MainActor final class AdapterTests: XCTestCase {
    func testUnpreparedWhisperDoesNotDownloadAtUtteranceStart() async throws {
        let engine = WhisperKitEngine()
        var events: [SttEvent] = []
        for await event in engine.transcribe(ScriptedCaptureSource([]).frames(), vocabulary: .init(userID: "test", terms: [])) {
            events.append(event)
        }
        XCTAssertEqual(events, [.failure(.unavailable)])
        let available = await engine.modelAvailable
        XCTAssertFalse(available)
    }
    func testDescriptorsAreLocalAndArgmaxIsOptIn() {
        XCTAssertEqual(AppleSpeechEngine().descriptor.location, .onDevice)
        XCTAssertEqual(WhisperKitEngine().descriptor.location, .onDevice)
        #if !ENABLE_ARGMAX
        XCTAssertFalse(ArgmaxBuild.enabled)
        #endif
    }
}
