import SwiftUI
import UIKit
import AVFoundation
import AppModel
import Core
import Brain
import Stt
import SttApple
import BrainApple
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var host: AppRuntime
    @State private var localProviders = ProviderOrderDraft()
    @State private var cloudProviders = ProviderOrderDraft()
    @State private var showingInfo = false
    @State private var showingSimulatorDetails = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var retentionWarnings: [HistoryEntry] = []
    var body: some View {
        @Bindable var model = host.model
        Form {
            Section("Speech") {
                if typeSize.isAccessibilitySize { speechEnginePicker.pickerStyle(.inline) }
                else { speechEnginePicker.pickerStyle(.navigationLink) }
                if ArgmaxBuild.engine == nil { Text("Argmax unavailable — requires a licence and a loaded host adapter.").font(.footnote) }
                Toggle("Allow cloud processing", isOn: $model.settings.cloudConsent).accessibilityIdentifier("cloud-consent")
                Toggle("Maximum accuracy", isOn: $model.settings.maxAccuracy).accessibilityIdentifier("maximum-accuracy")
                Button("Download / prepare speech models") { Task { await host.prepareModels() } }
                #if DEBUG
                Toggle("Show A/B comparison tools", isOn: $model.settings.compare).accessibilityIdentifier("comparison-tools")
                if host.model.settings.compare {
                    Picker("Comparison engine", selection: $model.settings.comparisonEngine) {
                        Text("Apple").tag("apple"); Text("WhisperKit").tag("whisperkit")
                        if ArgmaxBuild.engine != nil { Text("Argmax Pro").tag("argmax") }
                        Text("ElevenLabs").tag("elevenlabs-scribe"); Text("AssemblyAI").tag("assemblyai")
                    }
                    NavigationLink("Run same-audio A/B comparison") { RecorderView(host: host) }
                }
                #endif
                Text("Cloud services use the signed relay membership from pairing.").font(.footnote)
            }
            Section("AI suggestions") {
                Toggle("Mute suggestions", isOn: Binding(get: { model.muted }, set: { value in Task { await model.muteSuggestions(value) } }))
                    .accessibilityIdentifier("mute-suggestions")
                Picker("Processing", selection: $model.settings.brain) {
                    Text("On-device only").tag(BrainSetting.onDeviceOnly.rawValue)
                    Text("Hybrid").tag(BrainSetting.hybrid.rawValue)
                    Text("Cloud only").tag(BrainSetting.cloudOnly.rawValue)
                }
                TextField("Relay Claude model", text: $model.settings.cloudModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Relay Anthropic API version", text: $model.settings.cloudAPIVersion).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Model and API version must match the relay deployment.").font(.footnote)
            }
            Section("Agent routing") {
                TextField("Local providers in fallback order (comma separated)", text: $localProviders.text)
                    .onChange(of: localProviders.text) { _, _ in model.settings.routing.localProviderOrder = localProviders.providers }
                TextField("Cloud providers in fallback order (comma separated)", text: $cloudProviders.text)
                    .onChange(of: cloudProviders.text) { _, _ in model.settings.routing.cloudProviderOrder = cloudProviders.providers }
            }
            Section("Vocabulary") {
                TextField("One word or phrase per line", text: Binding(get: { host.model.settings.vocabulary.joined(separator: "\n") },
                    set: { host.model.settings.vocabulary = $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }), axis: .vertical)
                    .autocorrectionDisabled()
            }
            Section("Connection") {
                TextField("Relay HTTPS URL", text: $model.settings.relayURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                LabeledContent("Account", value: model.accountID)
            }
            Section("Sleep, wake and audit copy") {
                Text(host.pushStatus)
                Text(host.archiveStatus)
                Button("Verify audit copy now") { Task { await host.maintainArchive(force: true) } }.disabled(host.archiveBusy)
            }

            ForEach(retentionWarnings, id: \.segmentID) { entry in
                Section("Held text: retention choice required") {
                    Text(entry.text).textSelection(.enabled)
                    Text("This text has reached its seven-day retention limit. Sending waits for your choice.").font(.footnote)
                    Button("Keep for seven more days") { resolveRetention(entry.segmentID, keep: true) }
                    Button("Delete text", role: .destructive) { resolveRetention(entry.segmentID, keep: false) }
                }
            }
            Section { NavigationLink("Benchmark recorder") { RecorderView(host: host) }.accessibilityIdentifier("benchmark-recorder") }
            #if DEBUG
            if host.demo != nil {
                Button("Simulator details") { showingSimulatorDetails.toggle() }
                    .frame(minHeight: 44).accessibilityIdentifier("settings-demo-details")
                    .accessibilityValue(showingSimulatorDetails ? "Expanded" : "Collapsed")
                if showingSimulatorDetails {
                    Text("Destination before capture: " + (host.demo?.destinationBeforeCapture == true ? "Yes" : "No")).accessibilityIdentifier("demo-order")
                    Text("Tasks: " + String(model.tasks.count)).accessibilityIdentifier("demo-tasks")
                    Text("Cloud processing: " + (model.settings.cloudConsent ? "On" : "Off") + "; saved: " + (host.savedCloudConsentForDemo.map { $0 ? "On" : "Off" } ?? "Not saved"))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("consent-state")
                }
            }
            #endif
        }.navigationTitle("Settings")
        .toolbar { Button("Privacy and help", systemImage: "info.circle") { showingInfo = true } }
        .sheet(isPresented: $showingInfo) { InfoSheet(title: "Privacy and settings", paragraphs: ["Cloud speech sends live audio to your configured proxy. Cloud brain sends text for proposals. Provider retention depends on your service. No vendor key is stored here.", "Choose the project, selected session and default in Agents. Named destinations stay constraints. Machine or file dependent work waits for its host.", "This installation uses one account. Account switching is unavailable. Set the relay before pairing; saved computers retain their paired relay address.", "Wake is a content-free hint. Fresh sessions query durable task identities; expired approvals and ambiguous deliveries stay held. Audit recovery requires fresh Face ID or phone passcode. Missing history is shown as lost, never silently reset.", "Get permission from participants before recording. Ordinary live audio is not saved. Offline remote recordings stay on the remote and phone until transcribed, then audio is deleted; late text goes to history only. Text expires after seven days. Held or uncertain dictation is shown for a Keep or Delete choice before expiry can remove it. Benchmark audio requires a separate explicit recording action.", "Cloud processing is optional and off by default. When enabled, speech sends audio and Brain sends text to the configured providers through the relay. The listening screen indicates cloud use. Provider retention and encryption policies require review before release."]) }
        .onAppear {
            localProviders = ProviderOrderDraft(text: model.settings.routing.localProviderOrder.joined(separator: ","))
            cloudProviders = ProviderOrderDraft(text: model.settings.routing.cloudProviderOrder.joined(separator: ","))
        }
        .onChange(of: model.settings) { _, _ in host.saveSettings() }
        .task {
            while !Task.isCancelled {
                await refreshRetention()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    private var speechEnginePicker: some View {
        Picker("Speech engine", selection: Binding(get: { host.model.settings.speechEngine }, set: { host.model.settings.speechEngine = $0 })) {
            Text("Automatic").tag("automatic"); Text("Apple SpeechAnalyzer").fixedSize(horizontal: false, vertical: true).tag("apple")
            Text("WhisperKit small.en").fixedSize(horizontal: false, vertical: true).tag("whisperkit")
            if ArgmaxBuild.engine != nil { Text("Argmax Pro (licensed, loaded)").tag("argmax") }
            Text("ElevenLabs Scribe").fixedSize(horizontal: false, vertical: true).tag("elevenlabs-scribe"); Text("AssemblyAI").tag("assemblyai")
        }
    }
    private func refreshRetention() async {
        do { retentionWarnings = try await host.historyStore.retentionWarnings(now: Int64(Date().timeIntervalSince1970 * 1000)) }
        catch { host.error = "Retention review is unavailable. Text has not been discarded." }
    }
    private func resolveRetention(_ id: String, keep: Bool) {
        Task {
            do {
                try await host.historyStore.resolveRetention(id: id, keep: keep, now: Int64(Date().timeIntervalSince1970 * 1000))
                await host.model.refresh(); await refreshRetention()
            } catch { host.error = "The retention choice could not be saved." }
        }
    }
}
private struct RecorderView: View {
    @Bindable var host: AppRuntime
    @State private var showingInfo = false
    @State private var share: URL?
    @State private var showingShare = false
    @State private var importingCommands = false
    @State private var exporting = false
    @State private var playback: AVAudioPlayer?
    @State private var stageEngine = ""
    @State private var deliveryStart = ""
    @State private var deliveryEnd = ""
    @State private var fieldConfirmed = ""
    var body: some View {
        @Bindable var recorder = host.recorder
        Form {
            Section("Owner benchmark") {
                Text("\(host.recorder.completed) / \(host.recorder.prompts.count) prompts completed")
                if let prompt = host.recorder.prompt {
                    Text(AppPresentation.recordingCategory(prompt.category)).font(.headline)
                    Text(prompt.expected_text).font(.title2).accessibilityLabel("Read aloud: " + prompt.expected_text)
                }
                Text("Input: " + AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", "))
                Toggle("Keep audio after export", isOn: $recorder.keepAudio).accessibilityIdentifier("keep-benchmark-audio")
                Button("Import 50 spoken-command prompts") { importingCommands = true }
                    .disabled(recorder.busy || recorder.completed > 0)
                Button("Listen to last recording for clipping") {
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback)
                        try AVAudioSession.sharedInstance().setActive(true)
                        playback = try AVAudioPlayer(data: recorder.lastRecordingWAV()); playback?.play()
                    } catch { host.error = "The private recording is no longer available for listening." }
                }.disabled(recorder.busy || recorder.completed == 0)
                Picker("Last recording: first word", selection: $recorder.clippingAnnotation) {
                    Text("TBD / not listened").tag("TBD")
                    Text("Clipped").tag("Clipped"); Text("Not clipped").tag("Not clipped")
                }.disabled(recorder.busy || recorder.completed == 0)
                .onChange(of: recorder.clippingAnnotation) { _, _ in recorder.annotateLastCapture() }
                Group {
                    TextField("Battery engine ID", text: $recorder.batteryEngineID)
                    TextField("Battery cohort ID", text: $recorder.batteryCohortID)
                    TextField("Elapsed seconds", text: $recorder.batteryDurationSeconds).keyboardType(.decimalPad)
                    TextField("Drain in percentage points", text: $recorder.batteryDrainPercentagePoints).keyboardType(.decimalPad)
                    TextField("Device, load and thermal conditions", text: $recorder.batteryConditions)
                }
                DisclosureGroup("Delivery / field measurements (optional)") {
                    TextField("Measured speech engine ID", text: $stageEngine)
                    TextField("Delivery started ms", text: $deliveryStart).keyboardType(.decimalPad)
                    TextField("Delivery completed ms", text: $deliveryEnd).keyboardType(.decimalPad)
                    TextField("Field confirmed ms", text: $fieldConfirmed).keyboardType(.decimalPad)
                    Button("Annotate last recording with measured offsets") {
                        do {
                            func offset(_ value: String) throws -> Double? {
                                if value.isEmpty { return nil }
                                guard let number = Double(value) else { throw SttFailure.invalidResponse }
                                return number
                            }
                            guard let id = recorder.lastCompletedCaseID else { throw SttFailure.unavailable }
                            try recorder.annotateStages(caseID: id, engineID: stageEngine, stages: .init(
                                deliveryStartedMS: offset(deliveryStart), deliveryCompletedMS: offset(deliveryEnd),
                                fieldConfirmedMS: offset(fieldConfirmed)))
                        } catch { host.error = "Supply ordered, correlated measurements for a recorded speech engine." }
                    }.disabled(recorder.busy || recorder.completed == 0)
                }
                if host.recorder.recording {
                    Label("Recording benchmark", systemImage: "record.circle.fill").foregroundStyle(.red)
                    Button("Finish") { host.recorder.finish() }
                    Button("Discard recording", role: .destructive) { host.recorder.cancel() }
                } else if host.recorder.busy { ProgressView("Transcribing…") }
                else { Button("Record prompt") { playback?.stop(); Task { await host.startRecorder() } } }
                if let message = host.recorder.message { Text(message) }
                Button(exporting ? "Exporting…" : "Export run JSON") {
                    exporting = true
                    Task { @MainActor in
                        defer { exporting = false }
                        do {
                            if recorder.isCommandRun {
                                share = try await recorder.prepareCommandExport(brain: FoundationModelsBrain(),
                                    engineID: "foundation-models", engineVersion: "iOS " + UIDevice.current.systemVersion)
                            } else { share = try recorder.prepareExport() }
                            showingShare = true
                        } catch { host.error = "Complete the recording cohort and check measurement fields before exporting." }
                    }
                }.disabled(host.recorder.busy || exporting)
                Button("Start a new microphone / command cohort") {
                    do { try recorder.startNewCohort() }
                    catch { host.error = "Finish sharing the current cohort before starting another." }
                }.disabled(!recorder.canStartNewCohort)

            }
        }.navigationTitle("Benchmark recorder")
        .toolbar { Button("About recorder", systemImage: "info.circle") { showingInfo = true } }
        .sheet(isPresented: $showingInfo) { InfoSheet(title: "Benchmark recorder", paragraphs: ["Use only your curated reading set. Recorder audio stays private on this phone. The shared JSON contains prompts and recognized text, not audio.", "Import SW/bench/sets/commands.json from Files before recording. Commands are proposed only and never executed. Speech engine one supplies the transcript; all 50 recordings are required. Export evaluates Apple Foundation Models on this phone.", "Optional battery cohort: measure a separate controlled interval with only the named engine running. Leave blank for TBD. A/B drain cannot be attributed to either engine.", "Cleanup offsets are measured automatically. Enter only independently correlated offsets in milliseconds from this recording's monotonic capture start. Transport write completion does not prove field insertion. Blank means TBD; this recorder does not inject text."]) }
        .sheet(isPresented: $showingShare) {
            if let share { RunShareSheet(url: share) { success in
                do { try host.recorder.exportCompleted(success: success) }
                catch { host.error = "Export finished, but local audio could not be removed." }
                showingShare = false
            } }
        }
        .fileImporter(isPresented: $importingCommands, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try recorder.loadCommands(Data(contentsOf: url))
            } catch { host.error = "Import the reviewed 50-command benchmark set before recording." }
        }
        .onDisappear { playback?.stop(); host.recorder.cancel() }
    }
}
private struct RunShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor @Sendable (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let completion = completion
        controller.completionWithItemsHandler = { @Sendable _, completed, _, error in
            let success = completed && error == nil
            Task { @MainActor in completion(success) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
