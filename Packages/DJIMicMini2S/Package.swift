// swift-tools-version: 6.0
import PackageDescription

/// DJI Mic Mini 2S support: the receiver's DUML control protocol over its USB vendor interface.
let package = Package(
    name: "DJIMicMini2S",
    platforms: [.macOS(.v15)],
    products: [.library(name: "DJIMicMini2S", targets: ["DJIMicMini2S"])],
    dependencies: [.package(path: "../MicSystemKit")],
    targets: [
        .target(name: "DJIMicMini2S", dependencies: ["MicSystemKit"]),
        .testTarget(name: "DJIMicMini2STests", dependencies: ["DJIMicMini2S"]),
    ],
    swiftLanguageModes: [.v5]
)
