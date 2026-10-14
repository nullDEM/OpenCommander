// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenCommanderCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenCommanderCore", targets: ["OpenCommanderCore"])
    ],
    targets: [
        .target(name: "OpenCommanderCore", path: "Sources/OpenCommanderCore"),
        .testTarget(
            name: "OpenCommanderCoreTests",
            dependencies: ["OpenCommanderCore"],
            path: "Tests/OpenCommanderCoreTests"
        )
    ]
)
