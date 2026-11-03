import Foundation
import VoiceRemoteProtocol

public enum InputActivation: Sendable { case inferred, ptt, wakeWord }
public enum InputMode: Sendable { case command, dictation }
public enum ApprovalSource: Sendable { case phone, remoteButton }
public enum DestinationKind: Sendable { case unknown, software, hardware }

/// Not Codable. Only the phone's authenticated input/registry composition root may
/// call PhoneInput. Importing model bytes cannot construct these capabilities.
public struct InputSession: Sendable, Equatable {
    public let account: String
    public let actor: String
    public let session: String
    public let device: String
    public let project: String
    public let destinationKind: DestinationKind
    fileprivate init(account: String, actor: String, session: String, device: String,
                     project: String, destinationKind: DestinationKind) {
        self.account = account; self.actor = actor; self.session = session
        self.device = device; self.project = project; self.destinationKind = destinationKind
    }
}

public struct ActivationEvidence: Sendable {
    public let session: InputSession
    public let requestID: UUID
    public let activation: InputActivation
    public let mode: InputMode
    public let ambiguousMeetingWake: Bool
    public let expiresAt: Int64
    fileprivate init(session: InputSession, requestID: UUID, activation: InputActivation,
                     mode: InputMode, ambiguousMeetingWake: Bool, expiresAt: Int64) {
        self.session = session; self.requestID = requestID; self.activation = activation
        self.mode = mode; self.ambiguousMeetingWake = ambiguousMeetingWake; self.expiresAt = expiresAt
    }
}

public struct ApprovalEvidence: Sendable {
    public let session: InputSession
    public let eventID: UUID
    public let requestID: UUID
    public let payloadHash: String
    public let source: ApprovalSource
    public let occurredAt: Int64
    fileprivate init(session: InputSession, eventID: UUID, requestID: UUID,
                     payloadHash: String, source: ApprovalSource, occurredAt: Int64) {
        self.session = session; self.eventID = eventID; self.requestID = requestID
        self.payloadHash = payloadHash; self.source = source; self.occurredAt = occurredAt
    }
}

/// A phone owner attests an observed effect. Not Codable and never model output.
public struct OwnerCompletionEvidence: Sendable {
    public let session: InputSession
    public let eventID: UUID
    public let commandID: String
    public let operationHash: String
    public let occurredAt: Int64
    fileprivate init(session: InputSession, commandID: String, operationHash: String, now: Int64) {
        self.session = session; eventID = UUID(); self.commandID = commandID
        self.operationHash = operationHash; occurredAt = now
    }
}

public struct GrantEvidence: Sendable {
    public let session: InputSession
    public let id: UUID
    public let capability: Capability
    public let risk: RiskClass
    public let expiresAt: Int64
    public let issuedAt: Int64
    fileprivate init(session: InputSession, id: UUID, capability: Capability, risk: RiskClass, expiresAt: Int64, issuedAt: Int64) {
        self.session = session; self.id = id; self.capability = capability
        self.risk = risk; self.expiresAt = expiresAt; self.issuedAt = issuedAt
    }
}

/// Trusted integration API, NOT a model tool. The app owns this object and never
/// feeds model-supplied identity, event IDs, scope, or timestamps into its methods.
/// Swift module visibility isolates data paths, not malicious native app code.
@MainActor public final class PhoneInput {
    private let now: () -> Int64
    public init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.now = now }

    public func session(account: String, actor: String, session: String, device: String,
                        project: String, destinationKind: DestinationKind) -> InputSession {
        InputSession(account: account, actor: actor, session: session, device: device,
                     project: project, destinationKind: destinationKind)
    }
    public func activation(session: InputSession, requestID: UUID = UUID(),
                           kind: InputActivation, mode: InputMode = .command,
                           ambiguousMeetingWake: Bool = false, expiresAt: Int64) -> ActivationEvidence {
        ActivationEvidence(session: session, requestID: requestID, activation: kind,
                           mode: mode, ambiguousMeetingWake: ambiguousMeetingWake, expiresAt: expiresAt)
    }
    public func approval(session: InputSession, requestID: UUID, payloadHash: String,
                         source: ApprovalSource = .phone) -> ApprovalEvidence {
        ApprovalEvidence(session: session, eventID: UUID(), requestID: requestID,
                         payloadHash: payloadHash, source: source, occurredAt: now())
    }
    /// Called only by the phone's "This finished" confirmation, after showing the
    /// exact task and provider session. It conveys no execution or approval authority.
    public func ownerCompletion(session: InputSession, commandID: String, operationHash: String) -> OwnerCompletionEvidence {
        OwnerCompletionEvidence(session: session, commandID: commandID, operationHash: operationHash, now: now())
    }
    /// Called after an explicit grant-settings confirmation, never by proposal decoding.
    public func grant(session: InputSession, capability: Capability, risk: RiskClass,
                      expiresAt: Int64) -> GrantEvidence {
        GrantEvidence(session: session, id: UUID(), capability: capability, risk: risk, expiresAt: expiresAt, issuedAt: now())
    }
}
