// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceRemoteProtocol",
    platforms: [.iOS("26.0")],
    products: [.library(name: "VoiceRemoteProtocol", targets: ["VoiceRemoteProtocol"])],
    targets: [
        .target(name: "VoiceRemoteProtocol", exclude: ["README.md"]),
        .testTarget(name: "VoiceRemoteProtocolTests", dependencies: ["VoiceRemoteProtocol"], exclude: ["README.md"])
    ]
)
