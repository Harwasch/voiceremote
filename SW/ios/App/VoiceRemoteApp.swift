import SwiftUI
import UIKit
import AppModel
import Core
import Stt
import Brain
import KeyboardBridge
import VoiceRemoteProtocol

@main struct VoiceRemoteApp: App {
    @State private var runtime: AppRuntime?
    @State private var startupError: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let runtime { ContentView(host: runtime) }
                else { ContentUnavailableView("Voice Remote", systemImage: "mic.slash", description: Text(startupError ?? "Starting…")) }
            }.task {
                guard runtime == nil else { return }
                do { let host = try AppRuntime.getOrCreate(); try await host.prepare(); runtime = host }
                catch { startupError = "Private storage could not be opened. Recording and approvals are unavailable." }
            }
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
            NavigationStack { SettingsView(host: host) }.tabItem { Label("Settings", systemImage: "gear") }
        }
        .sheet(isPresented: Binding(get: { host.model.approval != nil }, set: { if !$0 { host.model.dismissApproval() } })) {
            ApprovalView(model: host.model)
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
    @State private var triggerTimer: Task<Void, Never>?
    private var model: VoiceAppModel { host.model }
    private var tick: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    var body: some View {
        Form {
            if !host.permissionGranted {
                Section("Before recording") {
                    Text("Voice Remote uses your microphone to turn speech into text. Words go to the destination shown below. Dictation never sends a message. Audio is not saved unless you use the benchmark recorder. Cloud processing is off until you allow it.")
                    Button("Continue") { Task { await host.continuePermissions() } }
                }
            }
            Section {
                HStack(alignment: .top) {
                    Picker("Capture", selection: Binding(get: { model.controls.capture }, set: { model.setCapture($0) })) {
                        Text("OFF").tag(CaptureState.off); Text("HOLD").tag(CaptureState.hold); Text("CONTINUOUS").tag(CaptureState.continuous)
                    }.pickerStyle(.menu)
                    Picker("Mode", selection: Binding(get: { model.controls.mode }, set: { model.setMode($0) })) {
                        Text("Dictation").tag(Mode.dictation); Text("AI Control").tag(Mode.ai_control)
                    }.pickerStyle(.menu)
                }.disabled(!host.permissionGranted || host.recorder.recording)
                NavigationLink { TargetPickerView(model: model) } label: {
                    LabeledContent("Destination", value: model.destination?.display_name ?? (model.controls.target == .auto ? "Auto → iPhone" : "Destination unavailable"))
                }
                Label(model.isRecording ? "Recording" : model.listening.rawValue.capitalized,
                    systemImage: model.isRecording ? "record.circle.fill" : "mic.slash")
                    .foregroundStyle(model.isRecording ? Color.red : Color.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                if model.cloudInUse || host.brainCloudInUse { Label("Cloud in use", systemImage: "cloud.fill") }
                Button {} label: {
                    Label(held ? "Listening — release to finish" : "Hold to talk", systemImage: "mic.fill")
                        .font(.title2).frame(maxWidth: .infinity, minHeight: 92)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.controls.capture == .off || !host.permissionGranted || host.recorder.recording)
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($touching) { _, state, _ in state = true }.onChanged { _ in
                    guard !held else { return }; held = true; model.press(at: tick)
                    triggerTimer = Task { @MainActor in
                        while !Task.isCancelled { model.advanceTrigger(to: tick); try? await Task.sleep(for: .milliseconds(25)) }
                    }
                }.onEnded { _ in
                    held = false; triggerTimer?.cancel(); model.release(at: tick)
                })
                .accessibilityLabel("Hold to talk. Select HOLD or CONTINUOUS first.")
                .accessibilityAction(named: "Start recording") { model.setCapture(.continuous) }
                .accessibilityAction(named: "Finish utterance") { model.finishUtterance() }
                Button("Finish utterance", systemImage: "checkmark") { model.finishUtterance() }.disabled(!model.isRecording)
                Button("Stop immediately", systemImage: "stop.fill", role: .destructive) {
                    held = false; triggerTimer?.cancel(); model.stop(); host.recorder.cancel()
                }.accessibilityHint("Stops the microphone and discards unfinished text.")
                if !model.partial.isEmpty { Text(model.partial).textSelection(.enabled) }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            }
            Section { Text("Holds start after 300 ms. Two short taps lock recording. Continuous listening never authorizes an action.").font(.footnote) }
        }
        .navigationTitle(ContentView.title)
        .task { await model.refresh() }
        .onChange(of: touching) { _, active in
            if !active && held { cancelHold() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelHold(); model.leaveForeground() }
        }
        .onDisappear { cancelHold() }
    }
    private func cancelHold() {
        triggerTimer?.cancel(); triggerTimer = nil
        if held { held = false; model.cancelGesture() }
    }
}
struct TargetPickerView: View {
    let model: VoiceAppModel
    var body: some View {
        List {
            Button { model.setTarget(.auto) } label: { row("Auto", selected: model.controls.target == .auto) }
            Button { model.setTarget(.device(model.phoneID)) } label: { row("iPhone", selected: model.controls.target == .device(model.phoneID)) }
            ForEach(model.devices.filter { $0.capabilities.contains(.receive_text) }, id: \.device_id) { device in
                Button { model.setTarget(.device(device.device_id)) } label: { row(device.display_name, selected: model.controls.target == .device(device.device_id)) }
            }
            Text("Auto uses the most recent focused text field, otherwise iPhone. Changing destination stops the current utterance.").font(.footnote)
        }.navigationTitle("Destination")
    }
    private func row(_ name: String, selected: Bool) -> some View {
        HStack { Text(name); Spacer(); if selected { Image(systemName: "checkmark").accessibilityLabel("Selected") } }
    }
}
private struct HistoryView: View {
    let model: VoiceAppModel
    var body: some View {
        List {
            Text("Text only. Held and unconfirmed text stays until you delete it. Other text expires after seven days.").font(.footnote)
            ForEach(model.history.reversed(), id: \.segmentID) { entry in
                VStack(alignment: .leading) {
                    Text(entry.text).textSelection(.enabled)
                    Text(entry.targetID).font(.caption).foregroundStyle(.secondary)
                    if let origin = model.offlineOrigins[entry.segmentID] { Text(origin.label).font(.caption) }
                    if let state = model.deliveryStates[entry.segmentID] {
                        Text(state.label).font(.caption)
                        if [.held, .failed, .unconfirmed].contains(state) {
                            Button(state == .unconfirmed ? "Resend after checking computer" : "Send to computer") {
                                Task { await model.sendHeld(entry.segmentID) }
                            }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button("Copy") {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: entry.text]], options: [
                                .localOnly: true, .expirationDate: Date().addingTimeInterval(BridgePolicy.retention)
                            ])
                        }
                        ShareLink(item: entry.text) { Text("Share") }
                    }.buttonStyle(.borderless)
                }.swipeActions { Button("Delete", role: .destructive) { Task { await model.deleteHistory(entry.segmentID) } } }
            }
        }.navigationTitle("History").task { await model.refresh() }
    }
}
private struct SuggestionsView: View {
    let model: VoiceAppModel
    var body: some View {
        List {
            Toggle("Mute during meetings", isOn: Binding(get: { model.muted }, set: { value in Task { await model.muteSuggestions(value) } }))
            ForEach(model.suggestions) { card in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested").font(.headline)
                    Text(String(describing: card.proposal.tool)).textSelection(.enabled)
                    Text("Expires \(card.expiresAt, style: .relative)").font(.caption)
                    HStack {
                        Button("Review") { Task { await model.review(card) } }
                        Button("Dismiss", role: .destructive) { Task { await model.dismiss(card) } }
                        Menu("Edit target") {
                            ForEach(model.devices, id: \.device_id) { device in
                                Button(device.display_name) { Task { await model.editTarget(card, device: device) } }
                            }
                        }
                    }.buttonStyle(.borderless)
                }
            }
            ForEach(model.tasks, id: \.command.command_id) { task in Text(task.visibleStatus) }
        }.navigationTitle("Suggestions")
    }
}
private struct ApprovalView: View {
    let model: VoiceAppModel
    @State private var approving = false
    var body: some View {
        NavigationStack {
            Form {
                if let card = model.approval {
                    Section("Exact action") { Text(card.exactAction).font(.body.monospaced()).textSelection(.enabled) }
                    Section("Destination") { Text(card.destination.display_name); Text(card.destination.device_id).font(.caption) }
                    Section("Consequences") { Text(card.consequences) }
                    Section {
                        if card.preview.risk == .sensitive { Label("Face ID or iPhone passcode required", systemImage: "faceid") }
                        Button(model.canRetryQueue ? "Retry queue" : (card.preview.risk == .sensitive ? "Authenticate and approve" : "Approve exact action")) {
                            approving = true
                            Task { await model.approve(); approving = false }
                        }.disabled(approving)
                        Button("Deny", role: .destructive) { model.dismissApproval() }
                        if let message = model.message { Text(message) }
                    }
                }
            }.navigationTitle("Review action")
        }.interactiveDismissDisabled(approving)
    }
}
