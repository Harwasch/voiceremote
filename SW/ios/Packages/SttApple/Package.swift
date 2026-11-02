// swift-tools-version: 6.0
import PackageDescription
import Foundation

// No private registry resolution or licence requirement in ordinary builds.
// After licensing, configure Argmax's Swift registry and run with ENABLE_ARGMAX=1.
let enableArgmax = ProcessInfo.processInfo.environment["ENABLE_ARGMAX"] == "1"
var dependencies: [Package.Dependency] = [
    .package(path: "../Stt"),
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.14.1")
]
var products: [Target.Dependency] = ["Stt", .product(name: "WhisperKit", package: "WhisperKit")]
if enableArgmax {
    dependencies.append(.package(id: "argmaxinc.argmax-sdk-swift", .upToNextMinor(from: "1.7.0")))
    products.append(.product(name: "Argmax", package: "argmaxinc.argmax-sdk-swift"))
}
let package = Package(
    name: "SttApple", platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SttApple", targets: ["SttApple"])],
    dependencies: dependencies,
    targets: [
        .target(name: "SttApple", dependencies: products, path: "Sources", exclude: ["README.md"],
                swiftSettings: enableArgmax ? [.define("ENABLE_ARGMAX")] : []),
        .testTarget(name: "SttAppleTests", dependencies: ["SttApple"], path: "Tests", exclude: ["README.md"])
    ]
)
