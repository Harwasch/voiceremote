// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brain",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "Brain", targets: ["Brain"])],
    dependencies: [.package(path: "../Protocol")],
    targets: [
        .target(name: "Brain", dependencies: [.product(name: "VoiceRemoteProtocol", package: "Protocol")],
                path: "Sources", exclude: ["README.md", "Resources/README.md"], resources: [.process("Resources")]),
        .testTarget(name: "BrainTests", dependencies: ["Brain"], path: "Tests", exclude: ["README.md"])
    ]
)
