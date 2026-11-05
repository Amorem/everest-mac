// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "everest",
    platforms: [.macOS(.v13)],
    dependencies: [
        // App updates only (never the keyboard's firmware). Keep the version
        // in step with SPARKLE_VERSION in scripts/sparkle-tools.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "everest",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/everest",
            // Where the binary finds Sparkle.framework: in the app bundle, and
            // next to it for `swift build`.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            ])]
        ),
        .testTarget(
            name: "everestTests",
            dependencies: ["everest"],
            path: "Tests/everestTests"
        ),
    ]
)
