// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Router",
    platforms: [.iOS("26.0")],
    products: [.library(name: "Router", targets: ["Router"])],
    dependencies: [.package(path: "../Protocol"), .package(path: "../Policy")],
    targets: [
        .target(name: "Router", dependencies: [.product(name: "VoiceRemoteProtocol", package: "Protocol"), .product(name: "Policy", package: "Policy")],
                path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "RouterTests", dependencies: ["Router", .product(name: "TrustedInput", package: "Policy")], path: "Tests", exclude: ["README.md"])
    ]
)
