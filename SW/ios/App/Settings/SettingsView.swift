import SwiftUI
import UIKit
import AVFoundation
import AppModel
import Brain

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
                if host.recorder.recording {
                    Label("Recording benchmark", systemImage: "record.circle.fill").foregroundStyle(.red)
                    Button("Finish phrase") { host.recorder.finish() }
                    Button("Discard recording", role: .destructive) { host.recorder.cancel() }
                } else if host.recorder.busy { ProgressView("Transcribing…") }
                else { Button("Record prompt") { Task { await host.startRecorder() } } }
                if let message = host.recorder.message { Text(message) }
                Button("Export run JSON") {
                    do { share = try host.recorder.prepareExport(); showingShare = true }
                    catch { host.error = "Finish at least one prompt before exporting." }
                }.disabled(host.recorder.busy)
            }
        }.navigationTitle("Benchmark recorder")
        .sheet(isPresented: $showingShare) {
            if let share { RunShareSheet(url: share) { success in
                do { try host.recorder.exportCompleted(success: success) }
                catch { host.error = "Export finished, but local audio could not be removed." }
                showingShare = false
            } }
        }
        .onDisappear { host.recorder.cancel() }
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
