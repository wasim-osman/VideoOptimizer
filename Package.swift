// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VideoOptimizer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VideoOptimizerCore", targets: ["VideoOptimizerCore"]),
        .executable(name: "VideoOptimizerCLI", targets: ["VideoOptimizerCLI"]),
        .executable(name: "VideoOptimizerApp", targets: ["VideoOptimizerApp"]),
    ],
    targets: [
        .target(
            name: "VideoOptimizerCore",
            dependencies: []
        ),
        .executableTarget(
            name: "VideoOptimizerCLI",
            dependencies: ["VideoOptimizerCore"]
        ),
        .testTarget(
            name: "VideoOptimizerCoreTests",
            dependencies: ["VideoOptimizerCore"],
            swiftSettings: [
                // swift-testing ships with the Command Line Tools, but SwiftPM only
                // looks for its macro plugin under a full Xcode. Point at it directly
                // so `swift test` works without installing Xcode.
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ]),
            ]
        ),
        .executableTarget(
            name: "VideoOptimizerApp",
            dependencies: ["VideoOptimizerCore"],
            path: "Sources/VideoOptimizerApp"
        ),
    ]
)
