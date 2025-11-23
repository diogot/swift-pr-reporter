// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-pr-reporter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PRReporterKit", targets: ["PRReporterKit"])
    ],
    dependencies: [
        // No external dependencies - pure Swift
    ],
    targets: [
        .target(
            name: "PRReporterKit",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "PRReporterKitTests",
            dependencies: ["PRReporterKit"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
