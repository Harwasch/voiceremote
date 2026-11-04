// Purpose: signed-app push registration and content-free background reconciliation.
// Inputs: relay wake contract / Apple lifecycle; SDK/device execution unverified.
import UIKit
import BackgroundTasks
import AppModel
import VoiceRemoteProtocol

@MainActor final class PhoneWakeDelegate: NSObject, UIApplicationDelegate {
    static let refreshID = "com.harwasch.voiceremote.audit-refresh"
    static var environment: RelayWakeRegistrationEnvironment? {
        switch Bundle.main.object(forInfoDictionaryKey: "VoiceRemotePushEnvironment") as? String {
        case "development": .sandbox
        case "production": .production
        default: nil
        }
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Default builds contain no aps entitlement. The owner opts in using
        // Push.entitlements plus the matching signed provisioning profile.
        #if !targetEnvironment(simulator)
        if Self.environment != nil { application.registerForRemoteNotifications() }
        #endif
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard let environment = Self.environment else { return }
        Task {
            do {
                let host = try AppRuntime.getOrCreate(); try await host.prepare()
                await host.registeredForWake(token: deviceToken, environment: environment)
            } catch { AppRuntime.shared?.pushStatus = "Push registration unavailable while protected storage is locked." }
        }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppRuntime.shared?.pushStatus = "APNs registration failed. Check the signed profile and push entitlement."
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: userInfo), PhoneWake.isHint(bytes) else {
            completionHandler(.noData); return
        }
        let fetch = WakeFetch(completion: completionHandler)
        fetch.start()
    }
    static func scheduleVerification() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { AppRuntime.shared?.archiveStatus = "Background audit scheduling unavailable; verification runs on foreground/reconnect." }
    }
    static func verifyArchiveInBackground() async {
        defer { scheduleVerification() }
        do {
            let host = try AppRuntime.getOrCreate()
            host.acceptingRemoteControl = UIApplication.shared.applicationState == .active
            try await host.prepare(); try Task.checkCancellation()
            await host.maintainArchive()
        } catch { AppRuntime.shared?.archiveStatus = "Scheduled verification incomplete; audit copy unverified." }
    }
}

/// One completion per callback, even when storage/transport ignores cancellation.
/// The OS may never grant background time; foreground verification is mandatory.
@MainActor private final class WakeFetch {
    private var completion: ((UIBackgroundFetchResult) -> Void)?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    init(completion: @escaping (UIBackgroundFetchResult) -> Void) { self.completion = completion }
    func start() {
        work = Task { [self] in
            do {
                let host = try AppRuntime.getOrCreate()
                host.acceptingRemoteControl = UIApplication.shared.applicationState == .active
                try await host.prepare(); try Task.checkCancellation()
                try await host.reconcileWake()
                finish(.newData)
            } catch { finish(.failed) }
        }
        deadline = Task { [self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            work?.cancel(); AppRuntime.shared?.cancelWakeReconciliation(); finish(.failed)
        }
    }
    private func finish(_ result: UIBackgroundFetchResult) {
        guard let completion else { return }
        self.completion = nil; deadline?.cancel(); deadline = nil; work = nil
        completion(result)
    }
}
