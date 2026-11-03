import ActivityKit

struct VoiceRemoteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var destination: String
    }
}
