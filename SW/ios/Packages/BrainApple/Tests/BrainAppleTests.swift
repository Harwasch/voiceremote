import XCTest
import Brain
@testable import BrainApple

final class BrainAppleTests: XCTestCase, @unchecked Sendable {
    func testDownloadRequiresExplicitOptIn() async {
        let brain = MLXBrain(configuration: .init(modelID: "fictional/test-model"))
        do {
            _ = try await brain.propose(.init(accountID: "a", transcript: "open dashboard", context: "fictional"))
            XCTFail("Download without runtime opt-in")
        } catch { XCTAssertEqual(error as? BrainError, .unavailable) }
    }
}
