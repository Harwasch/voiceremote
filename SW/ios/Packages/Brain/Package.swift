// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brain",
    products: [.library(name: "Brain", targets: ["Brain"])],
    targets: [
        .target(name: "Brain", path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "BrainTests", dependencies: ["Brain"], path: "Tests", exclude: ["README.md"])
    ]
)
