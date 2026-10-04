// swift-tools-version: 6.0
import PackageDescription

/// What every mic system module builds on: the `MicSystem` contract and shared USB helpers.
let package = Package(
    name: "MicSystemKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MicSystemKit", targets: ["MicSystemKit"])],
    targets: [
        .target(name: "MicSystemKit"),
        .testTarget(name: "MicSystemKitTests", dependencies: ["MicSystemKit"]),
    ],
    swiftLanguageModes: [.v5]
)
