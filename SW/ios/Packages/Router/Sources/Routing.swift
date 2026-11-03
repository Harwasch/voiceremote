import Foundation
import VoiceRemoteProtocol

/// Full execution identity. Equality never implies continuity across hosts/providers.
public struct SessionIdentity: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let account: String
    public let host: String
    public let workspace: String
    public let providerSessionID: String
    public let executionWorkspace: String?
    public let capabilityProfile: String

    public init(provider: String, account: String, host: String, workspace: String,
                providerSessionID: String, capabilityProfile: String, executionWorkspace: String? = nil) {
        self.provider = provider; self.account = account; self.host = host
        self.workspace = workspace; self.providerSessionID = providerSessionID; self.executionWorkspace = executionWorkspace
        self.capabilityProfile = capabilityProfile
    }
}

public struct Destination: Codable, Equatable, Sendable {
    public let id: String
    public let session: SessionIdentity
    public let isCloud: Bool
    public let capabilities: [Capability]
    public var available: Bool
    public let lastUsed: Int64

    public init(id: String, session: SessionIdentity, isCloud: Bool = false,
                capabilities: [Capability], available: Bool, lastUsed: Int64 = 0) {
        self.id = id; self.session = session; self.isCloud = isCloud
        self.capabilities = capabilities; self.available = available; self.lastUsed = lastUsed
    }
}

/// Trusted policy supplies this metadata, never a model-facing proposal decoder.
public struct RoutingRules: Codable, Equatable, Sendable {
    public var explicitTarget: String?
    public var explicitProvider: String?
    public var explicitHost: String?
    public var explicitSession: SessionIdentity?
    public var selectedTarget: String?
    public var activeTextField: String?
    public var defaultTarget: String?
    public var dependencies: [String]?
    public var project: String
    public var mode: Mode = .ai_control
    public var capability: Capability = .delegate_task
    public var ambiguous = false
    public var machineDependency: String?
    public var cloudCapable = false
    public var allowCloudFallback = false
    public var localProviderOrder: [String] = []
    public var cloudProviderOrder: [String] = []

    public init(project: String) { self.project = project }
}

public enum HoldReason: String, Codable, Sendable {
    case unavailable, ambiguous, machineRequired, noAuthorizedDestination
    case deliveryUnknown, cancellationPending, reapprovalRequired, predecessorRequired
}

public struct RouteChoice: Codable, Equatable, Sendable {
    public let destination: Destination
    public let cloudFallback: Bool
    /// UI text names the actual route and never asserts cross-session continuity.
    public var label: String {
        "\(cloudFallback ? "Cloud fallback · new execution · " : "")\(destination.session.provider) / \(destination.session.host) / \(destination.session.workspace) / \(destination.session.providerSessionID)"
    }
}

public enum RouteDecision: Equatable, Sendable {
    case dispatch(RouteChoice)
    case hold(HoldReason)
}

public enum RouteResolver {
    public static func resolve(rules r: RoutingRules, destinations: [Destination]) -> RouteDecision {
        func matches(_ d: Destination) -> Bool {
            (r.explicitTarget == nil || d.id == r.explicitTarget) &&
            (r.explicitProvider == nil || d.session.provider == r.explicitProvider) &&
            (r.explicitHost == nil || d.session.host == r.explicitHost) &&
            (r.explicitSession == nil || d.session == r.explicitSession)
        }
        let preferredID = r.explicitTarget ?? r.selectedTarget ??
            (r.mode == .dictation ? r.activeTextField : nil) ?? r.defaultTarget
        if r.ambiguous, let preferred = destinations.first(where: { $0.id == preferredID }), !preferred.available {
            return .hold(.ambiguous)
        }
        let compatible = destinations.filter {
            $0.session.workspace == r.project && $0.capabilities.contains(r.capability) &&
            (!$0.isCloud || (r.cloudCapable && r.capability == .delegate_task && r.machineDependency == nil &&
                (r.allowCloudFallback || r.explicitTarget == $0.id || r.explicitHost == $0.session.host || r.explicitSession == $0.session)))
        }
        let named = compatible.filter(matches)
        func lookup(_ id: String?) -> Destination? { named.first { $0.id == id } }
        let recent = named.filter { $0.available && $0.lastUsed > 0 }.sorted {
            $0.lastUsed == $1.lastUsed ? $0.id < $1.id : $0.lastUsed > $1.lastUsed
        }.first
        let explicit = r.explicitTarget != nil || r.explicitProvider != nil ||
            r.explicitHost != nil || r.explicitSession != nil
        // A selected destination stays preferred even while offline. Recent sessions
        // alone skip offline entries; this is the five-step preference in §5.3.
        let preferred = lookup(r.explicitTarget) ?? lookup(r.selectedTarget) ??
            (r.mode == .dictation ? lookup(r.activeTextField) : nil) ?? recent ?? lookup(r.defaultTarget) ?? (explicit ? (named.first(where: { $0.available && !$0.isCloud }) ?? named.first) : nil)
        guard let primary = preferred else {
            return .hold(explicit ? .unavailable : .noAuthorizedDestination)
        }
        if let host = r.machineDependency, primary.session.host != host { return .hold(.machineRequired) }
        if primary.available { return .dispatch(RouteChoice(destination: primary, cloudFallback: primary.isCloud)) }
        if r.ambiguous { return .hold(.ambiguous) }
        // Named constraints remain hard constraints, including during fallback.
        for provider in r.localProviderOrder {
            if let target = named.first(where: {
                $0.available && !$0.isCloud && $0.session.host == primary.session.host &&
                $0.session.provider == provider
            }) { return .dispatch(RouteChoice(destination: target, cloudFallback: false)) }
        }
        if r.machineDependency != nil { return .hold(.machineRequired) }
        if r.cloudCapable && r.allowCloudFallback && r.capability == .delegate_task {
            for provider in r.cloudProviderOrder {
                if let target = named.first(where: {
                    $0.available && $0.isCloud && $0.session.provider == provider
                }) { return .dispatch(RouteChoice(destination: target, cloudFallback: true)) }
            }
        }
        return .hold(.unavailable)
    }
}
