import SwiftUI
import Core

@main
struct VoiceRemoteApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    static let title = AppIdentity.displayName

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.largeTitle)
            Text(Self.title).font(.title)
            Text("Ready for setup")
        }
        .padding()
    }
}
