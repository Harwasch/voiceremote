import Foundation

/// A user-requested removal attempts both memberships independently. Refusal of
/// the peer operation says nothing about whether self-removal was attempted.
public enum RelayMembershipCleanup {
    public static func perform(peer: String, local: String, revoke: @Sendable (String) async throws -> Void) async throws {
        var failure: (any Error)?
        for id in [peer, local] {
            do { try await revoke(id) }
            catch RelayError.httpRefused(403) { /* Already absent or no longer authorized. */ }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}
