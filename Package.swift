// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "OpenUsage",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OpenUsage", targets: ["OpenUsage"])
    ],
    targets: [
        .executableTarget(
            name: "OpenUsage",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
