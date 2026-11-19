// Purpose: plain UI wording only. Inputs: validated protocol/model values.
// Verification: portable presentation tests; no authorization or routing changes.
import Core
import Router
import VoiceRemoteProtocol

public enum AppPresentation {
    public static func summary(_ tool: ToolCall) -> String {
        switch tool {
        case .selectTargetTool(let value): "Use \(value.device_id) for text"
        case .openResourceTool(let value): "Open \(value.resource_uri) on \(value.device_id)"
        case .delegateTaskTool(let value): "Ask \(value.provider_session_id ?? value.device_id): \(value.instruction)"
        case .cancelTaskTool(let value): "Cancel task \(value.command_id)"
        case .prepareSendTool(let value): "Prepare a message to \(value.recipient): \(value.content)"
        }
    }
    public static func recordingCategory(_ value: String) -> String {
        switch value {
        case "normal": "Everyday speech"
        case "whispering": "Whispering"
        case "names": "Names"
        case "numbers": "Numbers"
        case "tech_terms": "Technical terms"
        default: "Recording prompt"
        }
    }
    public static func provider(_ value: String) -> String {
        switch value {
        case "codex": "Codex"
        case "claude": "Claude"
        case "cloud": "Cloud"
        default: value
        }
    }
    public static func profile(_ value: String) -> String {
        switch value {
        case "read_only": "Read only"
        case "workspace_write": "Can change workspace files"
        default: "Custom permissions"
        }
    }
    public static func microphone(choice: CaptureChoice, phone: String, remote: String?) -> String {
        switch choice {
        case .phone: phone
        case .remote: remote ?? "Remote unavailable — choose another microphone"
        case .automatic: remote.map { "Automatic: \(phone) or \($0)" } ?? phone
        }
    }
    public static func taskStatus(_ task: QueuedTask) -> String {
        let status: String
        if let hold = task.hold { status = hold.displayLabel }
        else if task.ownerConfirmed == true { status = "You confirmed this finished" }
        else if task.outcome == .dispatched && (task.state == .dispatched || task.state == .running) {
            status = "Delivered — check the result, then confirm it finished"
        } else { status = task.state.displayLabel }
        let destination = task.route?.label ?? task.rules.explicitTarget ?? task.rules.selectedTarget ?? task.rules.defaultTarget ?? "Choose a destination"
        return status + " · " + destination + (task.appReply.map { " · " + $0 } ?? "")
    }
}

public struct HomePresentation: Sendable {
    public let capture: CaptureState
    public let listening: ListeningState
    public init(capture: CaptureState, listening: ListeningState) { self.capture = capture; self.listening = listening }
    public var showsStop: Bool { listening == .preparing || listening == .listening || listening == .finishing }
    public var showsFinish: Bool { listening == .listening }
    public var showsHold: Bool { capture == .hold && listening != .preparing && listening != .finishing }
    public var showsStartContinuous: Bool { capture == .continuous && !showsStop && listening != .preparing }
    public var showsEnableCapture: Bool { capture == .off && !showsStop }
}

public extension Capability {
    var displayLabel: String {
        switch self {
        case .receive_text: "Type text"
        case .open_resource: "Open a file or link"
        case .delegate_task: "Ask an agent"
        case .cancel_task: "Cancel a task"
        case .external_send: "Prepare a message"
        }
    }
}
public extension RiskClass {
    var displayLabel: String {
        switch self {
        case .read_display: "Read only"
        case .workspace_modify: "Can change files"
        case .sensitive: "Requires authentication"
        }
    }
}
public extension DeviceInfoRole {
    var displayLabel: String {
        switch self {
        case .text_receiver: "Text receiver"
        case .agent: "Agent"
        case .both: "Text receiver and agent"
        case .capture: "Microphone"
        }
    }
}
public extension CaptureState {
    var displayLabel: String {
        switch self { case .off: "Off"; case .hold: "Hold"; case .continuous: "Continuous" }
    }
}
public extension Mode {
    var displayLabel: String { switch self { case .dictation: "Dictation"; case .ai_control: "AI Control" } }
}
public extension ListeningState {
    var displayLabel: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Getting ready"
        case .listening: "Listening"
        case .finishing: "Finishing"
        case .interrupted: "Interrupted"
        case .failed: "Recording unavailable"
        }
    }
}
public extension ExecutionState {
    var displayLabel: String {
        switch self {
        case .queued: "Waiting"
        case .dispatched: "Delivered"
        case .running: "Running"
        case .succeeded: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
public extension HoldReason {
    var displayLabel: String {
        switch self {
        case .unavailable: "Waiting for connection"
        case .ambiguous: "Choose a destination"
        case .machineRequired: "Waiting for this computer"
        case .noAuthorizedDestination: "Choose an allowed destination"
        case .deliveryUnknown: "Check delivery on the computer"
        case .cancellationPending: "Cancelling"
        case .reapprovalRequired: "Review again"
        case .predecessorRequired: "Waiting for the previous task"
        }
    }
}
