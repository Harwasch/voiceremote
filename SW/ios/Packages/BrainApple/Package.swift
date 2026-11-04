// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Disabled by default: no MLX dependency resolution or model download in the normal app build.
let enableMLX = ProcessInfo.processInfo.environment["VOICE_REMOTE_ENABLE_MLX"] == "1"
var dependencies: [Package.Dependency] = [.package(path: "../Brain")]
var targetDependencies: [Target.Dependency] = [.product(name: "Brain", package: "Brain")]
if enableMLX {
    dependencies.append(.package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"))
    dependencies.append(.package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.9.0"))
    dependencies.append(.package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0"))
    targetDependencies += [
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ]
}
let package = Package(
    name: "BrainApple",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "BrainApple", targets: ["BrainApple"])],
    dependencies: dependencies,
    targets: [
        .target(name: "BrainApple", dependencies: targetDependencies, path: "Sources", exclude: ["README.md"],
                swiftSettings: enableMLX ? [.define("VOICE_REMOTE_ENABLE_MLX")] : []),
        .testTarget(name: "BrainAppleTests", dependencies: ["BrainApple"], path: "Tests", exclude: ["README.md"])
    ]
)
