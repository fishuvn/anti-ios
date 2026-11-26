// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AntiCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "AntiCore",
            targets: ["AntiCore"]
        ),
    ],
    targets: [
        .target(
            name: "AntiCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "AntiCoreTests",
            dependencies: ["AntiCore"]
        ),
    ]
)
