// swift-tools-version: 6.2
import PackageDescription

// Warnings are errors for this package's own targets only, never for dependencies.
let ownSettings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "agent-balancer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .executable(name: "agent-balancer", targets: ["agent-balancer"]),
        .executable(name: "AgentBalancerBar", targets: ["AgentBalancerBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: [
        .target(
            name: "Core",
            swiftSettings: ownSettings
        ),
        .executableTarget(
            name: "agent-balancer",
            dependencies: [
                "Core",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: ownSettings
        ),
        .executableTarget(
            name: "AgentBalancerBar",
            dependencies: ["Core"],
            swiftSettings: ownSettings
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            swiftSettings: ownSettings
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["Core"],
            swiftSettings: ownSettings
        ),
    ]
)
