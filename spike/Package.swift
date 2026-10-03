// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ptpspike",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ptpspike",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ImageCaptureCore")]
        )
    ]
)
