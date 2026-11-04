import Foundation
import VoiceRemoteProtocol

public struct AuthenticationChallenge: Sendable, Equatable {
    public let id: UUID
    public let payloadHash: String
    public let issuedAt: Int64
    public let expiresAt: Int64
}

/// The trusted adapter returns which local credential succeeded. This record is
/// not a wire type; model output cannot be submitted as an authentication result.
public struct AuthenticationResult: Sendable {
    public let challenge: AuthenticationChallenge
    public let credential: ApprovalCredentialClass
    public let authenticatedAt: Int64
    public init(challenge: AuthenticationChallenge, credential: ApprovalCredentialClass, authenticatedAt: Int64) {
        self.challenge = challenge; self.credential = credential; self.authenticatedAt = authenticatedAt
    }
}

@MainActor public protocol Biometric {
    func authenticate(_ challenge: AuthenticationChallenge) async throws -> AuthenticationResult
}

#if canImport(LocalAuthentication)
import LocalAuthentication

/// Fresh context per challenge; no biometric reuse. Device-owner authentication
/// permits the phone passcode fallback. UI must display the gate's retained preview
/// before invoking approve. Never put content in the system authentication prompt.
@MainActor public final class LocalAuthenticationBiometric: Biometric {
    private let now: () -> Int64
    public init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.now = now }
    public func authenticate(_ challenge: AuthenticationChallenge) async throws -> AuthenticationResult {
        #if os(iOS)
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            throw PolicyError.invalid
        }
        // Invoke the callback API while isolated to MainActor. The callback
        // captures only a Sendable continuation, never LAContext or self. This
        // avoids sending a non-Sendable SDK context into a nonisolated async call
        // and then accessing it again in defer under Swift 6 strict concurrency.
        let authenticated = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "Approve the exact action shown on your phone",
                reply: { success, _ in continuation.resume(returning: success) })
        }
        guard authenticated else { throw PolicyError.invalid }
        // LA does not identify which factor satisfied deviceOwnerAuthentication.
        // Use the conservative allowed passcode class; never claim biometric proof.
        return AuthenticationResult(challenge: challenge, credential: .passcode, authenticatedAt: now())
        #else
        // macOS device-owner authentication can use factors outside phone policy.
        throw PolicyError.invalid
        #endif
    }
}
#endif
