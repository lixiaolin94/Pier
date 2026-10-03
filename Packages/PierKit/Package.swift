// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PierKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PierKit", targets: ["PierKit"]),
    ],
    targets: [
        .target(
            name: "PierKit",
            linkerSettings: [.linkedFramework("ImageCaptureCore")]
        ),
        .testTarget(name: "PierKitTests", dependencies: ["PierKit"]),
    ]
)
