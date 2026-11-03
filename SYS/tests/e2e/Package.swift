// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ProxyE2E", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../SW/ios/Packages/Pairing"), .package(path: "../../../SW/ios/Packages/Stt"), .package(path: "../../../SW/ios/Packages/Brain")],
    targets: [.executableTarget(name: "proxy-e2e", dependencies: ["Pairing", "Stt", "Brain"], path: "ProxyClient", exclude: ["README.md"])])
