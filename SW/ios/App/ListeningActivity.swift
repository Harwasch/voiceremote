import ActivityKit
import AppIntents

@MainActor final class ListeningActivity {
    // Activity is not Sendable in the SDK. Only its ID crosses actor boundaries;
    // the nonisolated operations below obtain their own task-local SDK handle.
    private var activityID: String?
    private var pendingUpdate: Task<Void, Never>?
    func setListening(_ listening: Bool, destination: String) {
        if listening {
            do {
                if let id = activityID {
                    enqueue { await ListeningActivityOperations.update(id: id, destination: destination) }
                } else { activityID = try ListeningActivityOperations.request(destination: destination) }
            } catch { AppRuntime.shared?.model.interrupt() }
        } else if let id = activityID {
            activityID = nil
            enqueue { await ListeningActivityOperations.end(id: id) }
        }
    }
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = pendingUpdate
        pendingUpdate = Task { await previous?.value; await operation() }
    }
}

private enum ListeningActivityOperations {
    nonisolated static func request(destination: String) throws -> String {
        try Activity.request(attributes: VoiceRemoteAttributes(), content: content(destination), pushType: nil).id
    }
    nonisolated static func update(id: String, destination: String) async {
        guard let activity = Activity<VoiceRemoteAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content(destination))
    }
    nonisolated static func end(id: String) async {
        guard let activity = Activity<VoiceRemoteAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
    nonisolated private static func content(_ destination: String) -> ActivityContent<VoiceRemoteAttributes.ContentState> {
        ActivityContent(state: .init(status: "Listening", destination: destination), staleDate: nil)
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
