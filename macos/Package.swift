// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyGit",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "MyGit",
            path: "Sources/MyGit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
