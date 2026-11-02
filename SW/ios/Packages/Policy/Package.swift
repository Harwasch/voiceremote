// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Policy",
    platforms: [.iOS(.v16), .macOS(.v13)],
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
