// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core", path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests", exclude: ["README.md"])
    ]
)
