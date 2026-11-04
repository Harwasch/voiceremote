import XCTest
@testable import Core

final class CoreTests: XCTestCase {
    func testDisplayNameIsSuitableForUI() {
        XCTAssertFalse(AppIdentity.displayName.isEmpty)
        XCTAssertEqual(AppIdentity.displayName.trimmingCharacters(in: .whitespacesAndNewlines), AppIdentity.displayName)
    }
}
