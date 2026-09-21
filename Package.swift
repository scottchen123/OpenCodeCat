// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "opencode-usage-widget",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenCodeCat",
            path: "Sources/opencode-usage-widget",
            resources: [.copy("CatFrames")],
            swiftSettings: [.define("SWIFT_PACKAGE")]
        )
    ]
)
