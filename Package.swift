// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Macam",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Macam", path: "Sources/Macam")
    ]
)
