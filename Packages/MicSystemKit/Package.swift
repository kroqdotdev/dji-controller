// swift-tools-version: 6.0
import PackageDescription

/// What every mic system module builds on: the `MicSystem` contract and shared control links.
let package = Package(
    name: "MicSystemKit",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "MicSystemKit", targets: ["MicSystemKit"]),
        // iOS only: the External Accessory control link. A library of its own so App Store builds,
        // which can't declare accessory protocols without the maker's approval, can leave it out.
        .library(name: "MicSystemAccessory", targets: ["MicSystemAccessory"]),
    ],
    targets: [
        .target(name: "MicSystemKit"),
        .target(name: "MicSystemAccessory", dependencies: ["MicSystemKit"]),
        .testTarget(name: "MicSystemKitTests", dependencies: ["MicSystemKit"]),
    ],
    swiftLanguageModes: [.v5]
)
