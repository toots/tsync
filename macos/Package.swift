// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "tsync",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "TsyncShared",
            path: "Shared"
        ),
    ]
)
