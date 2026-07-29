// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeStatus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeStatus",
            path: "Sources/ClaudeStatus"
        )
    ]
)
