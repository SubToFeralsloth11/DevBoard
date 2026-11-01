// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DevBoard",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DevBoard",
            path: "Sources/DevBoard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
