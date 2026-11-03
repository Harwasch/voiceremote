// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ProxyE2E", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../SW/ios/Packages/Pairing"), .package(path: "../../../SW/ios/Packages/Stt"), .package(path: "../../../SW/ios/Packages/Brain"), .package(path: "../../../SW/ios/Packages/AppModel"), .package(path: "../../../SW/ios/Packages/Policy"), .package(path: "../../../SW/ios/Packages/Router"), .package(path: "../../../SW/ios/Packages/Core"), .package(path: "../../../SW/ios/Packages/Protocol")],
    targets: [.executableTarget(name: "proxy-e2e", dependencies: ["Pairing", "Stt", "Brain", "AppModel", "Policy", "Router", "Core", .product(name: "TrustedInput", package: "Policy"), .product(name: "VoiceRemoteProtocol", package: "Protocol")], path: "ProxyClient", exclude: ["README.md"])])
