
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ColyseusExample",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    dependencies: [
        // Point at the local SDK package.
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "ColyseusExample",
            dependencies: [
                .product(name: "Colyseus", package: "Colyseus"),
            ],
            path: "ColyseusExample"
        ),
    ]
)
