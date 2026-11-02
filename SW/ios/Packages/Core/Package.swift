// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS("26.0")],
    products: [.library(name: "Core", targets: ["Core"])],
    dependencies: [.package(path: "../Protocol")],
    targets: [
        .target(name: "Core", dependencies: [.product(name: "VoiceRemoteProtocol", package: "Protocol")], path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests", exclude: ["README.md"])
    ]
)
