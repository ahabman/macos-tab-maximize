// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TabMaximize",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TabMaximize",
            path: "Sources/TabMaximize"
        )
    ]
)
