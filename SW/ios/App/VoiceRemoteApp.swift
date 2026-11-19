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
                        Text("Private storage / audit recovery").font(.title2)
                        Text(recovery.message)
                        if recovery.rooms.count > 1 {
                            Picker("Recovery archive", selection: $recovery.selectedRoom) {
                                ForEach(recovery.rooms, id: \.self) { room in Text(String(room.prefix(8))).tag(room) }
                            }
                        }
                        Button("Authenticate and restore verified audit copy") {
                            Task { if await recovery.recover() { await openRuntime() } }
                        }.buttonStyle(.glassProminent).controlSize(.large).disabled(recovery.busy)
                        Text("Missing keys, missing checkpoints or an unreplicated suffix cannot be silently reset. No old execution authority is renewed.").font(.footnote)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
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
            NavigationStack { HomeView(host: host) }.tabItem { Label("Home", systemImage: "mic") }
            NavigationStack { DevicesView(host: host) }.tabItem { Label("Devices", systemImage: "desktopcomputer") }
            NavigationStack { HistoryView(model: host.model) }.tabItem { Label("History", systemImage: "clock") }
            NavigationStack { SuggestionsView(model: host.model) }.tabItem { Label("Suggestions", systemImage: "lightbulb") }
            NavigationStack { AgentsView(model: host.model) }.tabItem { Label("Agents", systemImage: "person.2") }
        }
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
private struct HomeView: View {
    @Bindable var host: AppRuntime
    @State private var held = false
    @GestureState private var touching = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glassNamespace
    @State private var triggerTimer: Task<Void, Never>?
    @State private var showingInfo = false
    @State private var permissionStep = false
    @State private var showingSimulatorDetails = false
    private var model: VoiceAppModel { host.model }
    private var tick: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    private var destinationDisplay: String {
        model.destination?.display_name ?? (model.controls.target == .auto ? "Auto → iPhone" : "Destination unavailable")
    }
    private var presentation: HomePresentation { .init(capture: model.controls.capture, listening: model.listening) }
    private var opaqueControls: Bool {
        #if DEBUG
        if host.demo?.arguments.contains("--ui-reduce-transparency") == true { return true }
        #endif
        return reduceTransparency
    }
    var body: some View {
        Group {
            if !host.permissionGranted { permissionIntroduction }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(model.controls.mode.displayLabel, systemImage: model.controls.mode == .dictation ? "text.cursor" : "sparkles")
                                .font(.subheadline.weight(.semibold))
                            Text(host.recorder.recording ? "Benchmark recording" : model.listening.displayLabel).font(.largeTitle.bold())
                                .accessibilityIdentifier("listening-state")
                            NavigationLink { TargetPickerView(model: model) } label: {
                                Label("To " + destinationDisplay, systemImage: "arrow.up.right")
                                    .font(.title3).fixedSize(horizontal: false, vertical: true)
                                    .frame(minHeight: 44, alignment: .leading)
                            }.buttonStyle(.glass).accessibilityIdentifier("destination-link")
                                .disabled(host.recorder.recording)
                        }
                        if !model.partial.isEmpty {
                            Text(model.partial).font(.largeTitle.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("partial-text")
                        } else if model.isRecording {
                            Text("Speak naturally. Your words appear here.").font(.title2)
                        } else if model.controls.capture == .off {
                            Text("Turn capture on to talk").font(.title2)
                        } else {
                            Text("Your words, where you need them.").font(.title2)
                        }
                        talkControls
                        captureControls
                        LabeledContent("Microphone", value: host.activeSourceDisplay)
                            .font(.subheadline).accessibilityIdentifier("microphone-source")
                        if model.cloudInUse || host.brainCloudInUse { Label("Cloud in use", systemImage: "cloud.fill") }
                        if let message = model.message { Text(message).fixedSize(horizontal: false, vertical: true) }
                        #if DEBUG
                        if let demo = host.demo {
                            Button {
                                showingSimulatorDetails.toggle()
                            } label: {
                                Label("Simulator details", systemImage: showingSimulatorDetails ? "chevron.down" : "chevron.right")
                                    .font(.caption).frame(minHeight: 44)
                            }.accessibilityIdentifier("demo-disclosure")
                                .accessibilityValue(showingSimulatorDetails ? "Expanded" : "Collapsed")
                            if showingSimulatorDetails {
                                Text(model.listening.displayLabel + " · " + model.controls.capture.displayLabel).accessibilityIdentifier("demo-state")
                                Text("Destination before capture: " + (demo.destinationBeforeCapture ? "Yes" : "No")).accessibilityIdentifier("demo-order")
                                Text("Tasks: " + String(model.tasks.count)).accessibilityIdentifier("demo-tasks")
                            }
                        }
                        #endif
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(ContentView.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("About recording", systemImage: "info.circle") { showingInfo = true }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView(host: host) } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("settings-link")
            }
        }
        .sheet(isPresented: $showingInfo) {
            InfoSheet(title: "Recording", paragraphs: [
                "The destination is shown before the first word. Dictation types text and never presses Send or Enter.",
                "Hold starts after a short press. Two quick taps keep recording. Continuous listening never approves an action.",
                "Finish keeps the completed phrase. Stop turns capture off and discards unfinished text. You can also choose Off at any time.",
                "Live audio is not saved. The benchmark recorder is separate. Ask participants before recording. Cloud processing is off until you allow it in Settings."
            ])
        }
        .task {
            await model.refresh()
            #if DEBUG
            if host.demo?.arguments.contains("--ui-holding-preview") == true { startHold() }
            #endif
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .sensoryFeedback(.selection, trigger: held)
        .onChange(of: model.isRecording) { _, recording in
            UIImpactFeedbackGenerator(style: recording ? .light : .medium).impactOccurred()
        }
        .onChange(of: touching) { _, active in if !active && held { cancelHold() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelHold(); model.leaveForeground() } }
        .onDisappear { cancelHold() }
    }
    private var permissionIntroduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: permissionStep ? "mic.badge.plus" : "waveform").font(.largeTitle).accessibilityHidden(true)
                Text(permissionStep ? "Allow microphone and speech access" : "Speak. See. Choose.").font(.largeTitle.bold())
                Text(permissionStep ? "Your microphone captures your voice. Speech recognition turns it into words. You can change access in iPhone Settings." : "See where your words will go before you speak. Dictation types text; it never sends a message.")
                    .font(.title3).fixedSize(horizontal: false, vertical: true)
                Text("Live audio isn’t saved. Cloud processing is off until you choose it.")
                if permissionStep {
                    Button("Allow access") { Task { await host.continuePermissions() } }
                        .buttonStyle(.glassProminent).controlSize(.large).accessibilityIdentifier("permission-allow")
                } else {
                    Button("Continue") { permissionStep = true }.buttonStyle(.glassProminent).controlSize(.large)
                        .accessibilityIdentifier("permission-continue")
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var captureControls: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Capture").font(.caption.weight(.semibold)).accessibilityIdentifier("capture-label")
                    Picker("Capture", selection: Binding(get: { model.controls.capture }, set: { model.setCapture($0) })) {
                        Text("Off").tag(CaptureState.off); Text("Hold").tag(CaptureState.hold); Text("Continuous").tag(CaptureState.continuous)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(minHeight: 44).accessibilityLabel("Capture").accessibilityIdentifier("capture-picker")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode").font(.caption.weight(.semibold)).accessibilityIdentifier("mode-label")
                    Picker("Mode", selection: Binding(get: { model.controls.mode }, set: { model.setMode($0) })) {
                        Text("Dictation").tag(Mode.dictation); Text("AI Control").tag(Mode.ai_control)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(minHeight: 44).accessibilityLabel("Mode").accessibilityIdentifier("mode-picker")
                }
            }
            .disabled(host.recorder.recording)
        }
    }
    // One stable control occupies the same layout and glass shape in every state.
    // No layout transition: inserting/removing controls must never overlap content.
    private var talkControls: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 16) {
                if host.recorder.recording {
                    Text("The benchmark recorder is using the microphone. Finish or discard its recording in Settings.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Group {
                        if held || (presentation.showsHold && !presentation.showsStop) {
                            Button {} label: { primaryLabel }
                                .simultaneousGesture(DragGesture(minimumDistance: 0)
                                    .updating($touching) { _, state, _ in state = true }
                                    .onChanged { _ in startHold() }
                                    .onEnded { _ in
                                        guard held else { return }
                                        held = false; triggerTimer?.cancel(); model.release(at: tick)
                                    })
                                .accessibilityIdentifier("hold-to-talk")
                                .accessibilityHint("Hold while speaking and release to finish. VoiceOver users can choose Start recording in Actions.")
                                .accessibilityAction(named: "Start recording") { model.setCapture(.continuous) }
                                .accessibilityAction(named: "Finish") {
                                    guard model.isRecording else { return }
                                    held = false; triggerTimer?.cancel(); model.finishUtterance()
                                }
                        } else {
                            Button {
                                if model.listening == .preparing { return }
                                if presentation.showsEnableCapture { model.setCapture(.hold) }
                                else if presentation.showsStartContinuous { model.setCapture(.continuous) }
                                else if presentation.showsStop { stop() }
                            } label: { primaryLabel }
                                .disabled(model.listening == .preparing)
                                .accessibilityIdentifier(primaryIdentifier)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(opaqueControls ? primaryTint : .clear, in: .rect(cornerRadius: 32))
                    .glassEffect(opaqueControls ? .identity : .regular.tint(primaryTint).interactive(), in: .rect(cornerRadius: 32))
                    .glassEffectID("talk", in: glassNamespace)
                    if presentation.showsStop && (held || model.listening == .preparing) {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) { stop() }
                            .frame(minHeight: 44).buttonStyle(.glass).foregroundStyle(.red)
                            .accessibilityIdentifier("stop-immediately")
                    }
                    if presentation.showsFinish && !held {
                        Button("Finish", systemImage: "checkmark") { model.finishUtterance() }
                            .frame(minHeight: 44).buttonStyle(.glass).accessibilityIdentifier("finish-utterance")
                    }
                }
            }
        }
    }
    private var primaryLabel: some View {
        VStack(spacing: 12) {
            if model.listening == .preparing {
                ProgressView().tint(.white).accessibilityHidden(true)
            } else {
                Image(systemName: primarySymbol).font(.largeTitle).accessibilityHidden(true)
            }
            Text(primaryTitle).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 116).padding(20)
            .contentShape(.rect(cornerRadius: 32))
    }
    private var primaryTitle: String {
        if model.listening == .preparing { return "Getting ready" }
        if held { return "Release to finish" }
        if presentation.showsStop { return "Stop" }
        if presentation.showsEnableCapture { return "Turn capture on" }
        if presentation.showsStartContinuous { return "Start listening" }
        return "Hold to talk"
    }
    private var primarySymbol: String { presentation.showsStop && !held ? "stop.fill" : "mic.fill" }
    private var primaryTint: Color { presentation.showsStop ? .red : .accentColor }
    private var primaryIdentifier: String {
        if model.listening == .preparing { return "preparing-talk" }
        if held || (presentation.showsHold && !presentation.showsStop) { return "hold-to-talk" }
        if presentation.showsStop { return "stop-immediately" }
        return presentation.showsEnableCapture ? "enable-capture" : "start-continuous"
    }
    private func startHold() {
        guard !held else { return }; held = true; model.press(at: tick)
        triggerTimer = Task { @MainActor in
            while !Task.isCancelled { model.advanceTrigger(to: tick); try? await Task.sleep(for: .milliseconds(25)) }
        }
    }
    private func stop() { held = false; triggerTimer?.cancel(); model.stop(); host.recorder.cancel() }
    private func cancelHold() {
        triggerTimer?.cancel(); triggerTimer = nil
        if held { held = false; model.cancelGesture() }
    }
}
struct TargetPickerView: View {
    let model: VoiceAppModel
    var body: some View {
        List {
            Button { model.setTarget(.auto) } label: { row("Auto", selected: model.controls.target == .auto) }.accessibilityIdentifier("target-auto")
            Button { model.setTarget(.device(model.phoneID)) } label: { row("iPhone", selected: model.controls.target == .device(model.phoneID)) }.accessibilityIdentifier("target-phone")
            ForEach(model.devices.filter { $0.capabilities.contains(.receive_text) }, id: \.device_id) { device in
                Button { model.setTarget(.device(device.device_id)) } label: { row(device.display_name, selected: model.controls.target == .device(device.device_id)) }.accessibilityIdentifier("target-" + device.device_id)
            }
            Text("Auto follows the most recent text field, or uses iPhone. Changing destination stops the current phrase.").font(.subheadline)
        }.navigationTitle("Destination")
    }
    private func row(_ name: String, selected: Bool) -> some View {
        HStack { Text(name).fixedSize(horizontal: false, vertical: true); Spacer(); if selected { Image(systemName: "checkmark").accessibilityLabel("Selected") } }.frame(minHeight: 44)
    }
}
private struct HistoryView: View {
    let model: VoiceAppModel
    @State private var showingInfo = false
    var body: some View {
        List {
            if model.history.isEmpty { ContentUnavailableView("No text yet", systemImage: "text.bubble", description: Text("Your finished phrases appear here.")) }
            ForEach(model.history.reversed(), id: \.segmentID) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.text).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityIdentifier("history-" + entry.segmentID)
                    Text(model.devices.first(where: { $0.device_id == entry.targetID })?.display_name ?? (entry.targetID == model.phoneID ? "iPhone" : entry.targetID)).font(.subheadline)
                    if let origin = model.offlineOrigins[entry.segmentID] { Text(origin.label).font(.subheadline) }
                    if let state = model.deliveryStates[entry.segmentID] { Text(state.label).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                    if let state = model.deliveryStates[entry.segmentID], [.held, .failed, .unconfirmed].contains(state) {
                        Button(state == .unconfirmed ? "Resend after checking computer" : "Send to computer") { Task { await model.sendHeld(entry.segmentID) } }
                            .frame(minHeight: 44).accessibilityIdentifier("send-" + entry.segmentID)
                    } else { Button("Copy", systemImage: "doc.on.doc") { copy(entry.text) }.frame(minHeight: 44) }
                    Menu("More", systemImage: "ellipsis") {
                        Button("Copy", systemImage: "doc.on.doc") { copy(entry.text) }
                        ShareLink(item: entry.text) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteHistory(entry.segmentID) } }
                    }.frame(minHeight: 44).accessibilityIdentifier("history-more-" + entry.segmentID)
                }.buttonStyle(.borderless)
                .swipeActions { Button("Delete", role: .destructive) { Task { await model.deleteHistory(entry.segmentID) } } }
            }
        }.navigationTitle("History").task { await model.refresh() }
        .toolbar { Button("About history", systemImage: "info.circle") { showingInfo = true } }
        .sheet(isPresented: $showingInfo) {
            InfoSheet(title: "Your text", paragraphs: ["Only text is kept here. Held and unconfirmed text stays until you delete it. Other text expires after seven days.", "Check the computer before resending unconfirmed text, so it isn’t inserted twice. Expired held text needs a Keep or Delete choice in Settings."])
        }
    }
    private func copy(_ text: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(BridgePolicy.retention)])
    }
}
private struct SuggestionsView: View {
    let model: VoiceAppModel
    var body: some View {
        List {
            Toggle("Mute during meetings", isOn: Binding(get: { model.muted }, set: { value in Task { await model.muteSuggestions(value) } })).accessibilityIdentifier("mute-suggestions")
            ForEach(model.suggestions) { card in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested").font(.headline)
                    Text(AppPresentation.summary(card.proposal.tool)).font(.title3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityIdentifier("suggestion-summary")
                    Text("Expires \(card.expiresAt, style: .relative)").font(.caption)
                    VStack(alignment: .leading) {
                        Button("Review") { Task { await model.review(card) } }.frame(minHeight: 44).accessibilityIdentifier("review-suggestion")
                        Menu("More", systemImage: "ellipsis") {
                            Button("Dismiss", role: .destructive) { Task { await model.dismiss(card) } }
                            Menu("Edit target") {
                                ForEach(model.devices, id: \.device_id) { device in
                                    Button(device.display_name) { Task { await model.editTarget(card, device: device) } }
                                }
                            }
                        }.frame(minHeight: 44)
                    }.buttonStyle(.borderless)
                }
            }
            if model.suggestions.isEmpty { ContentUnavailableView("No suggestions", systemImage: "lightbulb", description: Text("Choose AI Control on Home to review suggested actions here.")) }
        }.navigationTitle("Suggestions")
    }
}
private struct ApprovalView: View {
    let model: VoiceAppModel
    @State private var approving = false
    var body: some View {
        NavigationStack {
            ScrollView {
                if let card = model.approval {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(AppPresentation.summary(card.preview.tool)).font(.title2.bold()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("approval-exact-action")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Destination").font(.headline)
                            Text(card.destination.display_name)
                            Text(card.destination.device_id).font(.subheadline).textSelection(.enabled)
                                .frame(minHeight: 44, alignment: .leading)
                            if let route = card.routeDescription { Text(route).font(.subheadline).textSelection(.enabled).frame(minHeight: 44, alignment: .leading) }
                        }.fixedSize(horizontal: false, vertical: true)
                        Text(card.consequences).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("Exact details") { Text(card.exactAction).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        if card.preview.risk == .sensitive { Label("Face ID or iPhone passcode required", systemImage: "faceid") }
                        Button {
                            approving = true
                            Task { await model.approve(); approving = false }
                        } label: {
                            Label(model.canRetryQueue ? "Retry queue" : (card.preview.risk == .sensitive ? "Authenticate and approve" : "Approve exact action"),
                                systemImage: card.preview.risk == .sensitive ? "faceid" : "checkmark")
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.glassProminent).controlSize(.large).disabled(approving).accessibilityIdentifier("approve-action")
                        Button(role: .cancel) { model.dismissApproval() } label: {
                            Text("Don’t allow").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.glass).accessibilityIdentifier("approval-deny")
                        if let message = model.message { Text(message).fixedSize(horizontal: false, vertical: true) }
                    }.padding(24)
                }
            }.navigationTitle("Review action").navigationBarTitleDisplayMode(.inline)
        }.presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(approving)
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
        } else {
            content.preferredColorScheme(UIDemo.requested ? (arguments.contains("--ui-dark") ? .dark : .light) : nil)
        }
    }
}
#endif
