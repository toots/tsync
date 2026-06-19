// swift-tools-version: 5.9
import PackageDescription

// SPM builds the CLI and shared code. Extension + app require Xcode (app extension type).
let package = Package(
    name: "tsync",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tsync", targets: ["tsync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "TsyncShared",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
            ],
            path: "Shared"
        ),
        .executableTarget(
            name: "tsync",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SotoS3", package: "soto"),
                "TsyncShared",
            ],
            path: "tsync"
        ),
    ]
)
