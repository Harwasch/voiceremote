import Foundation
import Policy
import Router
import VoiceRemoteProtocol

public enum AppRoutingError: Error { case unsupportedAction, unavailableDestination, unknownProviderSession }
/// Only paired registry metadata and separately authenticated provider sessions
/// become routing candidates. A missing executor is a real durable hold.
@MainActor public enum RegisteredRouting {
    public static func enqueue(_ permit: ExecutionPermit, devices: [DeviceInfo], router: TaskRouter,
                               providerSessions: [Destination] = []) throws {
        let command = permit.command
        guard let device = devices.first(where: { $0.device_id == command.destination_id && $0.account_id == command.account_id }) else {
            throw AppRoutingError.unavailableDestination
        }
        let project: String, capability: Capability
        switch command.immutable_task_payload {
        case .openResourceTool: project = "default"; capability = .open_resource
        case .delegateTaskTool(let tool): project = tool.project_id; capability = .delegate_task
        default: throw AppRoutingError.unsupportedAction
        }
        guard device.capabilities.contains(capability) else { throw AppRoutingError.unavailableDestination }
        var rules = RoutingRules(project: project)
        rules.selectedTarget = device.device_id; rules.capability = capability
        if capability == .open_resource { rules.machineDependency = device.device_id }
        let destination: Destination
        if let session = command.provider_session_id {
            guard let existing = providerSessions.first(where: {
                $0.id == device.device_id && $0.session.account == device.account_id &&
                $0.session.workspace == project && $0.session.host == device.device_id && $0.session.providerSessionID == session
            }) else { throw AppRoutingError.unknownProviderSession }
            destination = existing
        } else {
            // This labels a machine-bound queue, not a provider's resumable session.
            destination = Destination(id: device.device_id, session: SessionIdentity(provider: "paired-device",
                account: device.account_id, host: device.device_id, workspace: project,
                providerSessionID: "machine-" + device.device_id, capabilityProfile: "paired"),
                capabilities: device.capabilities, available: false)
        }
        _ = try router.enqueue(permit, rules: rules, destinations: [destination])
        try router.reconnect(targets: [])
    }
}
