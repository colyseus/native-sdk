// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ColyseusExample",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The SDK, one directory up. Build its xcframework first:
        //   cd platforms/swift && ./build.sh
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "ColyseusExample",
            dependencies: [.product(name: "Colyseus", package: "swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
