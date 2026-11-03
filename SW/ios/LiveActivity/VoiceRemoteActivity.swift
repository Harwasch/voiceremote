import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VoiceRemoteActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceRemoteAttributes.self) { context in
            VStack { Text(context.state.status); Text("To: \(context.state.destination)") }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status)
                }
            } compactLeading: {
                Image(systemName: "waveform")
            } compactTrailing: {
                Text("VR")
            } minimal: {
                Image(systemName: "waveform")
            }
        }
    }
}
