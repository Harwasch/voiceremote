import XCTest
@testable import Stt

final class SttTests: XCTestCase {
    func testSampleCountsRejectNegativeValuesButAllowEmptyAudio() {
        XCTAssertNil(AudioSampleCount(-1))
        XCTAssertEqual(AudioSampleCount(0)?.value, 0)
        XCTAssertEqual(AudioSampleCount(160)?.value, 160)
    }
}
