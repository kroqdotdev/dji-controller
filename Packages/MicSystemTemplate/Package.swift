// swift-tools-version: 6.0
import PackageDescription

/// A starting point for a new mic system module. Copy this folder to Packages/<YourSystem> and
/// rename the package, target and type. See CONTRIBUTING.md, "Adding a mic system".
let package = Package(
    name: "MicSystemTemplate",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MicSystemTemplate", targets: ["MicSystemTemplate"])],
    dependencies: [.package(path: "../MicSystemKit")],
    targets: [
        .target(name: "MicSystemTemplate", dependencies: ["MicSystemKit"]),
        .testTarget(name: "MicSystemTemplateTests", dependencies: ["MicSystemTemplate"]),
    ],
    swiftLanguageModes: [.v5]
)
