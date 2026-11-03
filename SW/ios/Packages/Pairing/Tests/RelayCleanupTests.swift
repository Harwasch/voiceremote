import Foundation
import XCTest
@testable import Pairing

private actor CleanupSpy {
    var attempted: [String] = []
    var failLocal: Bool
    init(failLocal: Bool) { self.failLocal = failLocal }
    func revoke(_ id: String) throws {
        attempted.append(id)
        if id == "desktop" { throw RelayError.httpRefused(403) }
        if failLocal { throw RelayError.httpRefused(503) }
    }
}
final class RelayCleanupTests: XCTestCase, @unchecked Sendable {
    func testPeer403DoesNotSkipSelfRevokeOrHideItsFailure() async throws {
        for fail in [false, true] {
            let spy = CleanupSpy(failLocal: fail)
            do {
                try await RelayMembershipCleanup.perform(peer: "desktop", local: "phone") { try await spy.revoke($0) }
                XCTAssertFalse(fail)
            } catch { XCTAssertTrue(fail) }
            let attempted = await spy.attempted
            XCTAssertEqual(attempted, ["desktop", "phone"])
        }
    }
}
