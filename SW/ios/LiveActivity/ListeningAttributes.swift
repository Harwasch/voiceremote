import ActivityKit

struct VoiceRemoteAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var status: String
        var destination: String
    }
}
