// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "everest",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "everest",
            path: "Sources/everest"
        ),
        .testTarget(
            name: "everestTests",
            dependencies: ["everest"],
            path: "Tests/everestTests"
        ),
    ]
)
