#if DEBUG
import SwiftUI
import Stt
import SttApple

/// Minimal debug settings surface. Host reads these keys per utterance; no capture or network in this view.
struct EnginePickerView: View {
    @AppStorage("stt.engine") private var engine = "automatic"
    @AppStorage("stt.cloudConsent") private var cloudConsent = false
    @AppStorage("stt.maxAccuracy") private var maxAccuracy = false
    @AppStorage("stt.abEnabled") private var abEnabled = false
    @AppStorage("stt.abEngine") private var abEngine = "whisperkit"
    @AppStorage("stt.proxyURL") private var proxyURL = ""
    private var choices: [(String, String)] { [
        ("automatic", "Automatic"), ("apple", "Apple SpeechAnalyzer"),
        ("whisperkit", "WhisperKit small.en"), ("elevenlabs-scribe", "ElevenLabs Scribe v2"),
        ("assemblyai", "AssemblyAI Universal-3.5")
    ] + (ArgmaxBuild.enabled ? [("argmax", "Argmax Pro (unverified)")] : []) }
    private func reconcileComparison() {
        if abEngine == engine || !choices.contains(where: { $0.0 == abEngine && $0.0 != "automatic" }) {
            abEngine = choices.first(where: { $0.0 != engine && $0.0 != "automatic" })?.0 ?? "apple"
        }
    }
    var body: some View {
        Form {
            Picker("Speech engine", selection: $engine) {
                ForEach(choices, id: \.0) { id, label in Text(label).tag(id) }
            }
            Toggle("Allow cloud speech processing", isOn: $cloudConsent)
            Toggle("Maximum accuracy", isOn: $maxAccuracy)
            Toggle("Compare two engines", isOn: $abEnabled)
            if abEnabled {
                Picker("Comparison engine", selection: $abEngine) {
                    ForEach(choices.filter { $0.0 != "automatic" && $0.0 != engine }, id: \.0) { id, label in
                        Text(label).tag(id)
                    }
                }
                Text("A/B exports contain text. Save privately after reviewing both results.").font(.footnote)
            }
            TextField("Proxy WebSocket URL", text: $proxyURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Text("Cloud engines require your proxy. Live engines and phone measurements are unverified.").font(.footnote)
        }
        .navigationTitle("Speech engines")
        .onAppear { reconcileComparison() }
        .onChange(of: engine) { _, _ in reconcileComparison() }
    }
}
#endif
