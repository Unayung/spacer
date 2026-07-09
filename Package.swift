// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spacer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Spacer", path: "Sources/Spacer")
    ]
)
