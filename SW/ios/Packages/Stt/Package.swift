// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stt",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "Stt", targets: ["Stt"])],
    targets: [
        .target(name: "Stt", path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "SttTests", dependencies: ["Stt"], path: "Tests", exclude: ["README.md", "FakeWebSocket.py"])
    ]
)
