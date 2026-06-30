// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyGit",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // Syntax highlighting in the diff viewer (highlight.js via JavaScriptCore).
        // Ships a resource bundle (JS + themes) — run.sh copies *.bundle into the .app.
        .package(url: "https://github.com/raspu/Highlightr", from: "2.1.0")
    ],
    targets: [
        .executableTarget(
            name: "MyGit",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr")
            ],
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
