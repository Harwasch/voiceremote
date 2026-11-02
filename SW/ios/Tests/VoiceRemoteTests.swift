import XCTest
@testable import VoiceRemote

final class VoiceRemoteTests: XCTestCase {
    @MainActor
    func testShellDisplaysProductName() async {
        XCTAssertEqual(ContentView.title, "Voice Remote")
    }
}
