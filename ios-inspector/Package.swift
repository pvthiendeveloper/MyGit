// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyGitInspector",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MyGitInspector", targets: ["MyGitInspector"]),
    ],
    targets: [
        .target(name: "MyGitInspector"),
    ]
)
