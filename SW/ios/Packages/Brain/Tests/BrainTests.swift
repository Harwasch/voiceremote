import XCTest
@testable import Brain

final class BrainTests: XCTestCase {
    func testSkeletonStartsWithoutAnInferenceEngine() {
        XCTAssertFalse(BrainAvailability().isConfigured)
        XCTAssertTrue(BrainAvailability(isConfigured: true).isConfigured)
    }
}
