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
        .package(url: "https://github.com/raspu/Highlightr", from: "2.1.0"),
        // xterm terminal emulator + PTY (Miguel de Icaza) for the built-in terminal panel.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MyGit",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/MyGit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("WebKit")
            ]
        )
    ]
)
