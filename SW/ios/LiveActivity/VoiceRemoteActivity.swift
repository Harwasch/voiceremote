import ActivityKit
import SwiftUI
import WidgetKit

struct VoiceRemoteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
    }
}

@main
struct VoiceRemoteActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceRemoteAttributes.self) { context in
            Text("Voice Remote: \(context.state.status)").padding()
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
