// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AppModel", platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "AppModel", targets: ["AppModel"])],
    dependencies: ["Core", "Stt", "Brain", "Policy", "Router", "Pairing", "KeyboardBridge", "Protocol"].map { .package(path: "../" + $0) } + [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0")
    ],
    targets: [
        .target(name: "AppModel", dependencies: [.product(name: "Crypto", package: "swift-crypto"), "Core", "Stt", "Brain", "Policy", "Router", "Pairing", "KeyboardBridge",
            .product(name: "TrustedInput", package: "Policy"), .product(name: "VoiceRemoteProtocol", package: "Protocol")],
            path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "AppModelTests", dependencies: ["AppModel"], path: "Tests", exclude: ["README.md"])
    ])
