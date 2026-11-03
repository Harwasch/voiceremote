// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pairing",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "Pairing", targets: ["Pairing"]),
               .executable(name: "phone-e2e", targets: ["PhoneE2E"])],
    dependencies: [
        .package(path: "../Protocol"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0")
    ],
    targets: [
        .target(name: "Pairing", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "VoiceRemoteProtocol", package: "Protocol")
        ], path: "Sources", exclude: ["README.md"]),
        .executableTarget(name: "PhoneE2E", dependencies: ["Pairing"], path: "E2E", exclude: ["README.md"]),
        .testTarget(name: "PairingTests", dependencies: ["Pairing"], path: "Tests",
                    exclude: ["README.md"], resources: [.copy("Fixtures")])
    ]
)
