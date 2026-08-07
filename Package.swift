// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Spool",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "spool", path: "Sources/spool")
    ]
)
