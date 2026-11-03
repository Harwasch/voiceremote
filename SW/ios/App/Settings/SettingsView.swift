import SwiftUI
import UIKit
import AVFoundation
import AppModel
import Brain
import Stt
import SttApple
import BrainApple
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var host: AppRuntime
    @AppStorage("accountID") private var accountID = "owner-local"
    var body: some View {
        @Bindable var model = host.model
        Form {
            Section("Speech") {
                Picker("Speech engine", selection: $model.settings.speechEngine) {
                    Text("Automatic").tag("automatic"); Text("Apple SpeechAnalyzer").tag("apple")
                    Text("WhisperKit small.en").tag("whisperkit")
                    if ArgmaxBuild.engine != nil { Text("Argmax Pro (licensed, loaded)").tag("argmax") }
                    Text("ElevenLabs Scribe").tag("elevenlabs-scribe"); Text("AssemblyAI").tag("assemblyai")
                }
                Toggle("Allow cloud processing", isOn: $model.settings.cloudConsent)
                Text("Cloud speech sends live audio to your configured proxy. Cloud brain sends text for proposals. Provider retention depends on your service. No vendor key is stored here.").font(.footnote)
                Toggle("Maximum accuracy", isOn: $model.settings.maxAccuracy)
                Button("Download / prepare speech models") { Task { await host.prepareModels() } }
                #if DEBUG
                Toggle("Show A/B comparison tools", isOn: $model.settings.compare)
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
            Section("Brain") {
                Picker("Brain", selection: $model.settings.brain) {
                    Text("On-device only").tag(BrainSetting.onDeviceOnly.rawValue)
                    Text("Hybrid").tag(BrainSetting.hybrid.rawValue)
                    Text("Cloud only").tag(BrainSetting.cloudOnly.rawValue)
                }
                TextField("Relay Claude model", text: $model.settings.cloudModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Relay Anthropic API version", text: $model.settings.cloudAPIVersion).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Model and API version must match the relay deployment.").font(.footnote)
            }
            Section("Vocabulary") {
                TextField("One word or phrase per line", text: Binding(get: { host.model.settings.vocabulary.joined(separator: "\n") },
                    set: { host.model.settings.vocabulary = $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }), axis: .vertical)
                    .autocorrectionDisabled()
            }
            Section("Connection") {
                TextField("Relay HTTPS URL", text: $model.settings.relayURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Account identifier for pairing", text: $accountID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Changing account takes effect after restarting the app. Set the relay before pairing; saved computers retain their paired relay address.").font(.footnote)
            }
            Section { NavigationLink("Benchmark recorder") { RecorderView(host: host) } }
        }.navigationTitle("Settings")
        .onChange(of: model.settings) { _, _ in host.saveSettings() }
    }
}
private struct RecorderView: View {
    @Bindable var host: AppRuntime
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
                    Text(prompt.category.capitalized).font(.headline)
                    Text(prompt.expected_text).font(.title2).accessibilityLabel("Read aloud: " + prompt.expected_text)
                }
                Text("Use only your curated reading set. Recorder audio stays private on this phone. The shared JSON contains prompts and recognized text, not audio.").font(.footnote)
                Text("Input: " + AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", "))
                Toggle("Keep audio after export", isOn: $recorder.keepAudio)
                Button("Import 50 spoken-command prompts") { importingCommands = true }
                    .disabled(recorder.busy || recorder.completed > 0)
                Text("Import SW/bench/sets/commands.json from Files before recording. Commands are proposed only and never executed. Speech engine one supplies the transcript; all 50 recordings are required. Export evaluates Apple Foundation Models on this phone.").font(.footnote)
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
                    Text("Optional battery cohort: measure a separate controlled interval with only the named engine running. Leave blank for TBD. A/B drain cannot be attributed to either engine.").font(.footnote)
                    TextField("Battery engine ID", text: $recorder.batteryEngineID)
                    TextField("Battery cohort ID", text: $recorder.batteryCohortID)
                    TextField("Elapsed seconds", text: $recorder.batteryDurationSeconds).keyboardType(.decimalPad)
                    TextField("Drain in percentage points", text: $recorder.batteryDrainPercentagePoints).keyboardType(.decimalPad)
                    TextField("Device, load and thermal conditions", text: $recorder.batteryConditions)
                }
                DisclosureGroup("Delivery / field measurements (optional)") {
                    Text("Cleanup offsets are measured automatically. Enter only independently correlated offsets in milliseconds from this recording's monotonic capture start. Transport write completion does not prove field insertion. Blank means TBD; this recorder does not inject text.").font(.footnote)
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
                    Button("Finish phrase") { host.recorder.finish() }
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
