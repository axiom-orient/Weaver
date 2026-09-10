// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Weaver",
    platforms: [
        .iOS(.v16),
        .watchOS(.v8),
        .macOS(.v13)
    ],
    products: [
        .library(name: "Weaver", targets: ["Weaver"]),
        .executable(name: "DependencyDemoApp", targets: ["DependencyDemoApp"])
    ],
    targets: [
        .target(name: "Weaver"),
        .target(name: "DependencyDemoFeature"),
        .executableTarget(
            name: "DependencyDemoApp",
            dependencies: ["Weaver", "DependencyDemoFeature"]
        ),
        .testTarget(name: "WeaverTests", dependencies: ["Weaver"])
    ]
)
