// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pairing",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "Pairing", targets: ["Pairing"])],
    dependencies: [
        .package(path: "../Protocol"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0")
    ],
    targets: [
        .target(name: "Pairing", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "VoiceRemoteProtocol", package: "Protocol")
        ], path: "Sources", exclude: ["README.md"]),
        .testTarget(name: "PairingTests", dependencies: ["Pairing"], path: "Tests",
                    exclude: ["README.md"], resources: [.copy("Fixtures")])
    ]
)
