import SwiftUI
import UIKit
import AppModel
import Core
import VoiceRemoteProtocol

/// Approved Talk composition: destination, mode, words, then one talk control.
struct TalkView: View {
    @Bindable var host: AppRuntime
    let microphoneName: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var held = false
    @GestureState private var touching = false
    @State private var triggerTimer: Task<Void, Never>?
    @State private var startedAt: Date?
    @State private var showingDestination = false
    @State private var showingInfo = false
    @State private var permissionStep = false
    @Namespace private var controlsNamespace
    private var model: VoiceAppModel { host.model }
    private var tick: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    private var ai: Bool { model.controls.mode == .ai_control }
    private var modeTint: Color { ai ? Color(uiColor: .systemIndigo) : .blue }
    private var presentation: HomePresentation { .init(capture: model.controls.capture, listening: model.listening) }
    private var agentName: String? { (model.agentControl?.selected ?? model.agentControl?.routing.defaultSession)?.providerSessionID }
    private var destinationName: String {
        if ai { return agentName ?? "Choose an agent" }
        return model.destination?.display_name ?? (model.controls.target == .auto ? "This iPhone" : "Destination unavailable")
    }
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
                    VStack(alignment: .leading, spacing: 0) {
                        destination.dynamicTypeSize(...DynamicTypeSize.accessibility2).padding(.horizontal, 4).padding(.top, 20)
                        modePicker.padding(.top, 40)
                        words.dynamicTypeSize(...DynamicTypeSize.accessibility2).padding(.horizontal, 4).padding(.top, 38)
                        if ai {
                            ForEach(model.suggestions) { card in
                                SuggestionCardView(model: model, card: card).padding(.top, 20)
                            }
                        }
                        if let message = model.message {
                            Text(message).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 16)
                        }
                        if model.cloudInUse || host.brainCloudInUse { Label("Cloud in use", systemImage: "cloud.fill").font(.footnote).padding(.bottom, 12) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }.scrollEdgeEffectStyle(.soft, for: .all)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        talkControls.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(maxWidth: .infinity).padding(.horizontal, 20)
                            .padding(.top, model.isRecording ? 12 : 20).padding(.bottom, model.isRecording ? 8 : 32)
                            .background(Color(uiColor: .systemGroupedBackground))
                    }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { captureMenu }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView(host: host) } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("settings-link")
            }
        }
        .sheet(isPresented: $showingDestination) {
            TargetPickerView(model: model, connectedIDs: connectedIDs)
                #if DEBUG
                .modifier(UIDemoPresentation())
                #endif
        }
        .sheet(isPresented: $showingInfo) {
            InfoSheet(title: "Recording", paragraphs: [
                "The destination is shown before the first word. Dictation types text and never presses Send or Enter.",
                "Hold starts after a short press. Two quick taps keep recording. Continuous listening never approves an action.",
                "Finish keeps the completed phrase. Cancel turns capture off and discards unfinished text. You can also choose Off at any time.",
                "Live audio is not saved. The benchmark recorder is separate. Ask participants before recording. Cloud processing is off until you allow it in Settings."
            ])
        }
        .task {
            await model.refresh()
            #if DEBUG
            if let demo = host.demo, demo.arguments.contains("--ui-holding-preview"), !demo.holdingPreviewStarted {
                demo.holdingPreviewStarted = true; startHold()
            }
            #endif
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .sensoryFeedback(.selection, trigger: held)
        .onChange(of: model.isRecording) { _, recording in
            startedAt = recording ? Date() : nil
            UIImpactFeedbackGenerator(style: recording ? .light : .medium).impactOccurred()
        }
        .onChange(of: touching) { _, active in if !active && held { cancelHold() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelHold(); model.leaveForeground() } }
        .onDisappear { cancelHold() }
    }
    private var connectedIDs: Set<String> {
        #if DEBUG
        if host.demo != nil { return [UIDemo.computer.device_id] }
        #endif
        return host.link.connectedIDs
    }
    private var captureMenu: some View {
        Menu {
            Picker("Capture", selection: Binding(get: { model.controls.capture }, set: { model.setCapture($0) })) {
                Text("Hold").tag(CaptureState.hold)
                Text("Continuous").tag(CaptureState.continuous)
                Text("Off").tag(CaptureState.off)
            }
            if presentation.showsFinish { Button("Finish") { held = false; triggerTimer?.cancel(); model.finishUtterance() }.accessibilityIdentifier("finish-menu") }
            Divider()
            Button("About recording", systemImage: "info.circle") { showingInfo = true }
            Text("Microphone: " + microphoneName).accessibilityIdentifier("microphone-source")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.controls.capture == .hold ? "hand.draw" : (model.controls.capture == .off ? "mic.slash" : "waveform"))
                Text(model.controls.capture.displayLabel)
            }.font(.subheadline.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .fixedSize(horizontal: true, vertical: false).frame(minHeight: 44)
        }
        .accessibilityLabel("Capture").accessibilityValue(model.controls.capture.displayLabel)
        .accessibilityIdentifier("capture-menu").disabled(host.recorder.recording || !host.permissionGranted)
    }
    private var destination: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ai ? "Asking" : "Your words go to").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Button { showingDestination = true } label: {
                TalkDestinationTitle(name: destinationName)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(destinationName).accessibilityIdentifier("destination-link").disabled(host.recorder.recording)
            Text(destinationDetail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var destinationDetail: String {
        if ai {
            if let session = model.agentControl?.selected ?? model.agentControl?.routing.defaultSession {
                let hostName = model.devices.first(where: { $0.device_id == session.host })?.display_name ?? session.host
                return AppPresentation.provider(session.provider) + " on " + hostName + " · nothing runs without your OK"
            }
            return "Choose a session. Nothing runs without your OK."
        }
        let prefix = model.controls.target == .auto ? "Auto · " : ""
        if model.destination?.device_id == model.phoneID || model.destination == nil { return prefix + "Types with the Voice Remote keyboard" }
        if let id = model.destination?.device_id, connectedIDs.contains(id) { return prefix + "Ready for your words" }
        return prefix + "Offline · words wait until it’s back"
    }
    private var modePicker: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Menu {
                    modeSelection
                } label: {
                    Label(model.controls.mode.displayLabel, systemImage: ai ? "sparkles" : "text.cursor")
                        .font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.glass).accessibilityLabel("Mode").accessibilityValue(model.controls.mode.displayLabel).accessibilityIdentifier("mode-menu")
            } else {
                modeSelection.pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(minHeight: 48)
                    .accessibilityIdentifier("mode-picker")
            }
        }.tint(modeTint).disabled(host.recorder.recording)
    }
    private var modeSelection: some View {
        Picker("Mode", selection: Binding(get: { model.controls.mode }, set: { model.setMode($0) })) {
            Text("Dictation").tag(Mode.dictation)
            Text("AI Control").tag(Mode.ai_control)
        }.accessibilityLabel("Mode")
    }
    private var words: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.listening != .idle {
                HStack(spacing: 8) {
                    if model.listening == .listening { Circle().fill(ai ? modeTint : .red).frame(width: 8, height: 8).accessibilityHidden(true) }
                    Text(ai && model.listening == .listening ? "Listening for ideas" : model.listening.displayLabel)
                        .accessibilityIdentifier("listening-state")
                    if !ai, let startedAt, model.isRecording { Text(startedAt, style: .timer).monospacedDigit() }
                }.font(.footnote.weight(.semibold)).foregroundStyle(ai ? modeTint : .red)
            }
            if !model.partial.isEmpty {
                TalkTranscriptText(text: model.partial, ai: ai)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("partial-text")
            } else {
                TalkTranscriptText(text: instruction, ai: false).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.listening == .idle, let last = model.history.last(where: { model.deliveryStates[$0.segmentID] == .delivered }) {
                    Text("Last sent \(Date(timeIntervalSince1970: Double(last.createdAt) / 1000), style: .relative) ago: “\(last.text)”")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private var instruction: String {
        if model.controls.capture == .off { return "Turn capture on to talk" }
        if model.listening == .preparing { return "Getting your microphone ready…" }
        if model.listening == .finishing { return "Finishing your words…" }
        if model.isRecording { return "Speak naturally. Your words appear here." }
        if ai { return "Say what you’d like to do. You choose what happens next." }
        return "Hold the button and speak. Your words type where you're working."
    }
    private var talkControls: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                if host.recorder.recording {
                    Text("The benchmark recorder is using the microphone. Finish or discard its recording in Settings.").fixedSize(horizontal: false, vertical: true)
                } else if ai && model.controls.capture == .continuous && model.listening == .listening {
                    Button("Stop listening", systemImage: "stop.fill") { stop() }
                        .font(.headline).padding(.horizontal, 16).frame(minHeight: 40)
                        .buttonStyle(.glass).foregroundStyle(.red).frame(minHeight: 56).contentShape(Capsule()).accessibilityIdentifier("stop-immediately")
                        .accessibilityValue(model.listening.displayLabel)
                } else {
                    circleControl
                    Text(primaryTitle).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if presentation.showsStop {
                        Button(model.listening == .preparing || model.listening == .finishing ? "Stop" : "Cancel", role: .destructive) { stop() }
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 28)
                            .buttonStyle(.glass).foregroundStyle(.red).frame(minHeight: 44).contentShape(Capsule()).accessibilityIdentifier("stop-immediately")
                    }
                }
            }
        }
    }
    private var circleControl: some View {
        Group {
            if held || (presentation.showsHold && !presentation.showsStop) {
                Button {} label: { circleLabel }
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .updating($touching) { _, state, _ in state = true }
                        .onChanged { value in
                            if abs(value.translation.width) > 12 || abs(value.translation.height) > 12 { cancelHold() }
                            else { startHold() }
                        }
                        .onEnded { _ in
                            guard held else { return }
                            held = false; triggerTimer?.cancel(); model.release(at: tick)
                        })
                    .accessibilityIdentifier("hold-to-talk")
                    .accessibilityHint("Hold while speaking and release to finish. VoiceOver users can choose Start recording in Actions.")
                    .accessibilityAction(named: "Start recording") { model.setCapture(.continuous) }
                    .accessibilityAction(named: "Finish") { if model.isRecording { held = false; triggerTimer?.cancel(); model.finishUtterance() } }
            } else {
                Button {
                    if presentation.showsEnableCapture { model.setCapture(.hold) }
                    else if presentation.showsStartContinuous { model.setCapture(.continuous) }
                    else if model.isRecording { model.finishUtterance() }
                } label: { circleLabel }
                    .disabled(model.listening == .preparing || model.listening == .finishing)
                    .accessibilityIdentifier(primaryIdentifier)
            }
        }
        .buttonStyle(.plain).foregroundStyle(model.controls.capture == .off ? Color.primary : .white)
        .background(opaqueControls ? (model.controls.capture == .off ? Color(uiColor: .secondarySystemGroupedBackground) : primaryTint) : .clear, in: .circle)
        .glassEffect(opaqueControls ? .identity : .regular.tint(primaryTint.opacity(model.controls.capture == .off ? 0.18 : 1)).interactive(), in: .circle)
        .glassEffectID("talk", in: controlsNamespace)
        .background {
            if model.isRecording {
                Circle().fill(Color.red.opacity(0.14)).padding(-18)
                    .overlay { Circle().fill(Color.red.opacity(0.18)).padding(-6) }
                    .accessibilityHidden(true)
            }
        }
        .padding(model.isRecording ? 18 : 0)
        .accessibilityLabel(primaryTitle).accessibilityValue(model.listening.displayLabel)
    }
    private var circleLabel: some View {
        Group {
            if model.listening == .preparing || model.listening == .finishing { ProgressView().tint(.white) }
            else { Image(systemName: model.isRecording ? "waveform" : (model.controls.capture == .off ? "mic.slash" : "mic.fill")).font(.system(size: 40, weight: .medium)) }
        }.frame(width: 112, height: 112).contentShape(Circle()).accessibilityHidden(true)
    }
    private var primaryTint: Color { presentation.showsStop ? .red : (model.controls.capture == .off ? .gray : modeTint) }
    private var primaryTitle: String {
        if model.listening == .preparing { return "Getting ready" }
        if model.listening == .finishing { return "Finishing" }
        if held { return ai ? "Release to ask \(destinationName)" : "Release to type into \(destinationName)" }
        if model.isRecording { return "Tap to finish" }
        if presentation.showsEnableCapture { return "Turn capture on" }
        if presentation.showsStartContinuous { return "Start listening" }
        return "Hold to talk"
    }
    private var primaryIdentifier: String {
        if model.listening == .preparing { return "preparing-talk" }
        if model.listening == .finishing { return "finishing-talk" }
        if model.isRecording { return "finish-utterance" }
        return presentation.showsEnableCapture ? "enable-capture" : "start-continuous"
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
                    Button("Continue") { permissionStep = true }.buttonStyle(.glassProminent).controlSize(.large).accessibilityIdentifier("permission-continue")
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
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

// ScaledMetric reads the environment of these child views, after the range cap.
// A cap applied just to Text would not constrain metrics stored in TalkView.
private struct TalkDestinationTitle: View {
    let name: String
    @ScaledMetric(relativeTo: .largeTitle) private var size = 40
    @ScaledMetric(relativeTo: .title3) private var chevronSize = 22
    var body: some View {
        Text("\(name)\u{00a0}\(Text(Image(systemName: "chevron.down")).font(.system(size: chevronSize, weight: .semibold)).foregroundStyle(.secondary))")
            .font(.system(size: size, weight: .bold)).tracking(-0.8)
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
    }
}
private struct TalkTranscriptText: View {
    let text: String
    let ai: Bool
    @ScaledMetric(relativeTo: .title) private var size = 28
    var body: some View {
        Text(text).font(.system(size: ai ? size * 5 / 7 : size, weight: ai ? .medium : .semibold))
    }
}
