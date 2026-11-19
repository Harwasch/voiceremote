import SwiftUI
import UIKit
import AppModel
import Core
import Stt
import Brain
import KeyboardBridge
import VoiceRemoteProtocol

@main struct VoiceRemoteApp: App {
    @UIApplicationDelegateAdaptor(PhoneWakeDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var runtime: AppRuntime?
    @State private var startupError: String?
    @State private var recovery = AuditRecoveryController()
    @State private var lifecycle = PhoneSceneLifecycle()
    var body: some Scene {
        WindowGroup {
            Group {
                if let runtime { ContentView(host: runtime) }
                else if startupError != nil {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Your saved data needs attention").font(.largeTitle.bold()).accessibilityIdentifier("storage-recovery-title")
                        Text(recovery.message)
                        if recovery.rooms.count > 1 {
                            Picker("Saved copy", selection: $recovery.selectedRoom) {
                                ForEach(recovery.rooms, id: \.self) { room in Text(String(room.prefix(8))).tag(room) }
                            }
                        }
                        Button("Restore saved copy") {
                            Task { if await recovery.recover() { await openRuntime() } }
                        }.buttonStyle(.glassProminent).controlSize(.large).disabled(recovery.busy).accessibilityIdentifier("restore-saved-copy")
                        Text("Recording and approvals are paused. Restoring needs Face ID or your iPhone passcode. Your original data stays on this phone.").font(.body).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }.background(Color(uiColor: .systemGroupedBackground))
                } else { ContentUnavailableView("Voice Remote", systemImage: "mic.slash", description: Text("Starting…")) }
            }
            #if DEBUG
            .modifier(UIDemoPresentation())
            #endif
            .task {
                guard runtime == nil else { return }
                await openRuntime()
            }.onChange(of: scenePhase) { _, phase in
                guard let runtime else { return }
                runtime.acceptingRemoteControl = phase == .active
                #if DEBUG
                if runtime.demo != nil { return }
                #endif
                let resumed = lifecycle.transition(to: phase == .background ? .background : phase == .active ? .active : .inactive)
                if resumed {
                    Task {
                        do { try await runtime.reconcileWake(); await runtime.refreshWakeRegistration() }
                        catch { runtime.error = "Wake reconciliation incomplete. Pending tasks remain held or unconfirmed." }
                    }
                } else if phase == .background {
                    try? runtime.agentControl.prepareForWake()
                    PhoneWakeDelegate.scheduleVerification()
                }
            }
        }
        .backgroundTask(.appRefresh(PhoneWakeDelegate.refreshID)) {
            await PhoneWakeDelegate.verifyArchiveInBackground()
        }
    }
    @MainActor private func openRuntime() async {
        do {
            let host = try AppRuntime.getOrCreate(); try await host.prepare(); runtime = host
            #if DEBUG
            if host.demo != nil { return }
            #endif
            PhoneWakeDelegate.scheduleVerification()
        } catch {
            startupError = "Private storage could not be opened. Recording and approvals are unavailable."
            recovery.loadRooms()
        }
    }
}
struct ContentView: View {
    static let title = AppIdentity.displayName
    @Bindable var host: AppRuntime
    var body: some View {
        TabView {
            NavigationStack { TalkView(host: host, microphoneName: host.activeSourceDisplay) }.tabItem { Label("Talk", systemImage: "mic") }
            NavigationStack { HistoryView(model: host.model) }.tabItem { Label("History", systemImage: "clock") }
            NavigationStack { DevicesView(host: host) }.tabItem { Label("Devices", systemImage: "desktopcomputer") }
            NavigationStack { AgentsView(model: host.model) }.tabItem { Label("Agents", systemImage: "sparkles") }
        }
        .tint(host.model.controls.mode == .dictation ? .blue : Color(uiColor: .systemIndigo))
        .tabBarMinimizeBehavior(.never)
        .environment(\.defaultMinListRowHeight, 52)
        .sheet(isPresented: Binding(get: { host.model.approval != nil }, set: { if !$0 { host.model.dismissApproval() } })) {
            ApprovalView(model: host.model)
                #if DEBUG
                .modifier(UIDemoPresentation())
                #endif
        }
        .sheet(isPresented: Binding(get: { host.model.completion != nil }, set: { if !$0 { host.model.dismissTaskCompletion() } })) {
            TaskCompletionView(model: host.model)
                #if DEBUG
                .modifier(UIDemoPresentation())
                #endif
        }
        .alert("Voice Remote", isPresented: Binding(get: { host.error != nil }, set: { if !$0 { host.error = nil } })) {
            Button("OK") { host.error = nil }
        } message: { Text(host.error ?? "") }
    }
}
private struct TaskCompletionView: View {
    let model: VoiceAppModel
    var body: some View {
        NavigationStack {
            Form {
                if let card = model.completion {
                    Section("Confirm the observed effect") {
                        Text(card.instruction).textSelection(.enabled)
                        Text(card.task.route?.label ?? "Session unavailable").font(.caption.monospaced())
                        Text("Task: " + card.task.command.command_id).font(.caption.monospaced())
                        Text("Check the result yourself before confirming.").font(.headline)
                        DisclosureGroup("Why confirmation is needed") {
                            Text("A reply or a successful process exit confirms delivery only. The linked chain waits until you confirm this finished; the next step still needs its own approval.").fixedSize(horizontal: false, vertical: true)
                        }
                        Button("This finished") { Task { await model.confirmTaskFinished() } }.frame(minHeight: 44)
                        Button("Keep waiting") { model.dismissTaskCompletion() }.frame(minHeight: 44)
                    }
                }
            }.navigationTitle("Owner completion")
        }
    }
}

#if DEBUG
struct UIDemoPresentation: ViewModifier {
    private let arguments = ProcessInfo.processInfo.arguments
    func body(content: Content) -> some View {
        if UIDemo.requested && arguments.contains("--ui-largest") {
            content.preferredColorScheme(arguments.contains("--ui-dark") ? .dark : .light).dynamicTypeSize(.accessibility5)
                .transaction(Self.disableAnimations)
        } else if UIDemo.requested {
            content.preferredColorScheme(arguments.contains("--ui-dark") ? .dark : .light)
                .transaction(Self.disableAnimations)
        } else { content }
    }
    // SwiftUI may evaluate transforms away from the main actor. This transform
    // reads no runtime, environment or actor-isolated demo properties.
    private nonisolated static func disableAnimations(_ transaction: inout Transaction) {
        transaction.animation = nil; transaction.disablesAnimations = true
    }
}
#endif
