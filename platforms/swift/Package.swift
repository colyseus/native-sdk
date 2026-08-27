// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The C core is Zig as much as it is C — msgpack, http and the certificate
// store are Zig modules — so SPM cannot compile it from source. It arrives as
// a pre-built xcframework instead, produced by ./build.sh.
//
// By default that is the one in build/, which is what a checkout of this repo
// works against. Point the package at a published archive by exporting both:
//
//   COLYSEUS_XCFRAMEWORK_URL=https://.../Colyseus.xcframework.zip
//   COLYSEUS_XCFRAMEWORK_CHECKSUM=$(swift package compute-checksum ...)

let env = ProcessInfo.processInfo.environment

let cColyseus: Target = {
    guard let url = env["COLYSEUS_XCFRAMEWORK_URL"],
          let checksum = env["COLYSEUS_XCFRAMEWORK_CHECKSUM"]
    else {
        return .binaryTarget(name: "CColyseus", path: "build/Colyseus.xcframework")
    }
    return .binaryTarget(name: "CColyseus", url: url, checksum: checksum)
}()

let package = Package(
    name: "Colyseus",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "Colyseus", targets: ["Colyseus"]),
    ],
    targets: [
        .target(
            name: "Colyseus",
            dependencies: ["CColyseus"],
            path: "Sources/Colyseus",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                // A static library in an xcframework carries no dependency
                // information, so the frameworks the core reaches for — the
                // keychain, the system certificate store — are linked here.
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),

        cColyseus,

        .testTarget(
            name: "ColyseusTests",
            // The tests drive the C API directly as well as the Swift surface.
            dependencies: ["Colyseus", "CColyseus"],
            path: "Tests/ColyseusTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
