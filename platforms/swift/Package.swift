// swift-tools-version: 5.9
import PackageDescription

// MARK: - Package
//
// This package distributes the Colyseus Swift SDK in two modes:
//
// 1. SOURCE mode (default during development):
//    The Swift wrapper sources are compiled directly. The pre-built
//    xcframework is linked as a binary dependency.
//    Use: .package(path: "../..")
//
// 2. RELEASE mode (tagged GitHub releases):
//    Both the Swift sources and the libcolyseus static library are
//    bundled in a single xcframework and distributed as a binary target.
//    Consumers add:
//      .package(url: "https://github.com/colyseus/colyseus-sdk", from: "0.17.0")
//
// For source-mode development the xcframework must be built first:
//   cd platforms/swift && ./build.sh

let package = Package(
    name: "Colyseus",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        .library(
            name: "Colyseus",
            targets: ["Colyseus"]
        ),
    ],
    targets: [
        // Swift wrapper layer
        .target(
            name: "Colyseus",
            dependencies: ["CColyseus"],
            path: "Sources/Colyseus",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // C library xcframework (pre-built via build.sh)
        .binaryTarget(
            name: "CColyseus",
            path: "build/Colyseus.xcframework"
        ),

        .testTarget(
            name: "ColyseusTests",
            dependencies: ["Colyseus"],
            path: "Tests/ColyseusTests"
        ),
    ]
)
