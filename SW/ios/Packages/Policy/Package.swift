// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Policy",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Policy", targets: ["Policy"]),
        .library(name: "TrustedInput", targets: ["TrustedInput"])
    ],
    dependencies: [.package(path: "../Protocol")],
    targets: [
        .target(name: "TrustedInput", dependencies: [.product(name: "VoiceRemoteProtocol", package: "Protocol")], exclude: ["README.md"]),
        .target(name: "Policy", dependencies: ["TrustedInput", .product(name: "VoiceRemoteProtocol", package: "Protocol")], exclude: ["README.md"]),
        .testTarget(name: "PolicyTests", dependencies: ["Policy", "TrustedInput"], exclude: ["README.md"])
    ]
)
