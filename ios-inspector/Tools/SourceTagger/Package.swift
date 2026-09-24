// swift-tools-version:5.9
import PackageDescription

// Rewrites a copy of an iOS project's Swift sources so every SwiftUI view
// expression carries its original file:line:column, which MyGit's UI
// Inspector reads back from SwiftUI's view debug data.
let package = Package(
    name: "SourceTagger",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mygit-source-tagger", targets: ["mygit-source-tagger"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        .target(
            name: "SourceTaggerCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(name: "mygit-source-tagger", dependencies: ["SourceTaggerCore"]),
        .testTarget(name: "SourceTaggerTests", dependencies: ["SourceTaggerCore"]),
    ]
)
