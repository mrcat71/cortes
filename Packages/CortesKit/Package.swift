// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CortesKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CortesKit", targets: ["CortesKit"]),
        .executable(name: "cortes-cli", targets: ["cortes-cli"]),
    ],
    targets: [
        .target(
            name: "CortesKit",
            resources: [
                .copy("Resources/Voices"),
                .copy("Resources/Scenarios"),
            ]
        ),
        .executableTarget(name: "cortes-cli", dependencies: ["CortesKit"]),
        .testTarget(name: "CortesKitTests", dependencies: ["CortesKit"]),
    ]
)
