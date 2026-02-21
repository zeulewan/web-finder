// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WebFinder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WebFinder",
            path: "Sources"
        )
    ]
)
