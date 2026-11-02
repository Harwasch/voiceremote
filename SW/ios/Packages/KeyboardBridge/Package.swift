// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KeyboardBridge",
    platforms: [.iOS(.v16)],
    products: [.library(name: "KeyboardBridge", targets: ["KeyboardBridge"])],
    targets: [
        .target(name: "KeyboardBridge", path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "KeyboardBridgeTests", dependencies: ["KeyboardBridge"], path: "Tests", exclude: ["README.md"])
    ]
)
