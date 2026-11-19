// Purpose: presentation-only regressions. Inputs: synthetic tools and protocol enums.
// Verification: portable tests; Apple layout remains unverified.
import Foundation
import Testing
import Core
import Router
import VoiceRemoteProtocol
@testable import AppModel

@Test func toolSummariesUsePlainWordsForEveryToolAndPreserveExactContent() {
    let cases: [(ToolCall, String)] = [
        (.selectTargetTool(.init(account_id: "synthetic", device_id: "studio")), "Use studio for text"),
        (.openResourceTool(.init(account_id: "synthetic", device_id: "studio", resource_uri: "file:///synthetic/note")), "Open file:///synthetic/note on studio"),
        (.delegateTaskTool(.init(account_id: "synthetic", device_id: "studio", project_id: "demo", provider_session_id: "draft-session", instruction: "Draft a workspace note")), "Ask draft-session: Draft a workspace note"),
        (.cancelTaskTool(.init(account_id: "synthetic", command_id: "task-1")), "Cancel task task-1"),
        (.prepareSendTool(.init(account_id: "synthetic", device_id: "studio", recipient: "Synthetic recipient", content: "Exact synthetic text")), "Prepare a message to Synthetic recipient: Exact synthetic text"),
    ]
    for (tool, expected) in cases {
        #expect(AppPresentation.summary(tool) == expected)
        #expect(!AppPresentation.summary(tool).contains("Tool("))
        #expect(!AppPresentation.summary(tool).contains("VoiceRemoteProtocol"))
    }
    #expect(AppPresentation.summary(.delegateTaskTool(.init(account_id: "synthetic", device_id: "studio", project_id: "demo", instruction: "Keep\nall words"))) == "Ask studio: Keep\nall words")
}

@Test func protocolLabelsArePlainForEveryCase() {
    let capabilities: [(Capability, String)] = [(.receive_text, "Type text"), (.open_resource, "Open a file or link"), (.delegate_task, "Ask an agent"), (.cancel_task, "Cancel a task"), (.external_send, "Prepare a message")]
    let risks: [(RiskClass, String)] = [(.read_display, "Read only"), (.workspace_modify, "Can change files"), (.sensitive, "Requires authentication")]
    let roles: [(DeviceInfoRole, String)] = [(.text_receiver, "Text receiver"), (.agent, "Agent"), (.both, "Text receiver and agent"), (.capture, "Microphone")]
    let holds: [(HoldReason, String)] = [(.unavailable, "Waiting for connection"), (.ambiguous, "Choose a destination"), (.machineRequired, "Waiting for this computer"), (.noAuthorizedDestination, "Choose an allowed destination"), (.deliveryUnknown, "Check delivery on the computer"), (.cancellationPending, "Cancelling"), (.reapprovalRequired, "Review again"), (.predecessorRequired, "Waiting for the previous task")]
    for (value, label) in capabilities { #expect(value.displayLabel == label) }
    for (value, label) in risks { #expect(value.displayLabel == label) }
    for (value, label) in roles { #expect(value.displayLabel == label) }
    for (value, label) in holds { #expect(value.displayLabel == label) }
    #expect([CaptureState.off, .hold, .continuous].map(\.displayLabel) == ["Off", "Hold", "Continuous"])
    #expect([Mode.dictation, .ai_control].map(\.displayLabel) == ["Dictation", "AI Control"])
    #expect([ListeningState.idle, .preparing, .listening, .finishing, .interrupted, .failed].map(\.displayLabel) == ["Ready", "Getting ready", "Listening", "Finishing", "Interrupted", "Recording unavailable"])
    #expect([ExecutionState.queued, .dispatched, .running, .succeeded, .failed, .cancelled].map(\.displayLabel) == ["Waiting", "Delivered", "Running", "Finished", "Failed", "Cancelled"])
    #expect(["codex", "claude", "cloud", "Another provider"].map(AppPresentation.provider) == ["Codex", "Claude", "Cloud", "Another provider"])
    #expect(AppPresentation.profile("read_only") == "Read only")
    #expect(AppPresentation.profile("workspace_write") == "Can change workspace files")
    #expect(AppPresentation.profile("unknown-future-profile") == "Custom permissions")
}

@Test func homeControlsFollowCaptureAndListeningStates() {
    for capture in [CaptureState.off, .hold, .continuous] {
        for state in [ListeningState.idle, .preparing, .listening, .finishing, .interrupted, .failed] {
            let presentation = HomePresentation(capture: capture, listening: state)
            #expect(presentation.showsStop == ([.preparing, .listening, .finishing].contains(state)))
            #expect(presentation.showsFinish == (state == .listening))
            #expect(presentation.showsStartContinuous == (capture == .continuous && [.idle, .interrupted, .failed].contains(state)))
            #expect(presentation.showsHold == (capture == .hold && state != .preparing && state != .finishing))
        }
    }
    #expect(HomePresentation(capture: .off, listening: .idle).showsEnableCapture)
    #expect(!HomePresentation(capture: .continuous, listening: .listening).showsHold)
}

@Test func microphonePreviewNeverPromisesAnUnavailableRemoteOrHidesAnIdleSource() {
    #expect(AppPresentation.microphone(choice: .phone, phone: "iPhone microphone", remote: nil) == "iPhone microphone")
    #expect(AppPresentation.microphone(choice: .remote, phone: "iPhone microphone", remote: nil) == "Remote unavailable — choose another microphone")
    #expect(AppPresentation.microphone(choice: .remote, phone: "iPhone microphone", remote: "Desk remote") == "Desk remote")
    #expect(AppPresentation.microphone(choice: .automatic, phone: "Headset", remote: "Desk remote") == "Automatic: Headset or Desk remote")
    #expect(AppPresentation.microphone(choice: .automatic, phone: "Headset", remote: nil) == "Headset")
}

@Test func recordingCategoriesDoNotExposeWireNames() {
    #expect(["normal", "whispering", "names", "numbers", "tech_terms", "unknown"].map(AppPresentation.recordingCategory) ==
        ["Everyday speech", "Whispering", "Names", "Numbers", "Technical terms", "Recording prompt"])
}

@Test @MainActor func cloudConsentChangesTheRealSettingAndPersistsBothChoices() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
    let rig = try Rig()
    rig.model.settingsDidChange = { settings in
        do { try store.save(settings) } catch { Issue.record(error) }
    }
    #expect(!rig.model.settings.cloudConsent)
    for allowed in [true, false] {
        rig.model.settings.cloudConsent = allowed
        #expect(rig.model.settings.cloudConsent == allowed)
        #expect(try store.load()?.cloudConsent == allowed)
    }
}
