import ActivityKit
import AppIntents

@MainActor final class ListeningActivity {
    private var activity: Activity<VoiceRemoteAttributes>?
    func setListening(_ listening: Bool, destination: String) {
        if listening {
            let content = ActivityContent(state: VoiceRemoteAttributes.ContentState(status: "Listening", destination: destination), staleDate: nil)
            do {
                if let activity { Task { await activity.update(content) } }
                else { activity = try Activity.request(attributes: VoiceRemoteAttributes(), content: content, pushType: nil) }
            } catch { AppRuntime.shared?.model.interrupt() }
        } else if let current = activity {
            activity = nil
            Task { await current.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

/// AudioRecordingIntent requires an active Live Activity throughout recording.
/// https://developer.apple.com/documentation/appintents/audiorecordingintent
struct ToggleRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start or stop Voice Remote"
    static let description = IntentDescription("Record speech using your selected mode and destination.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        let host = try AppRuntime.getOrCreate()
        try await host.prepare()
        if host.model.isRecording { host.model.finishUtterance() }
        else {
            guard host.permissionGranted else { throw RecordingIntentError.openAppFirst }
            host.model.setCapture(.continuous)
        }
        return .result()
    }
}
enum RecordingIntentError: Error { case openAppFirst }
struct VoiceRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleRecordingIntent(), phrases: ["Record with \(.applicationName)"],
            shortTitle: "Voice Remote recording", systemImageName: "mic")
    }
}
