// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeechanUI",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NeechanUI", targets: ["NeechanUI"])
    ],
    dependencies: [
        .package(path: "../NeechanAPI"),
        .package(path: "../NeechanCore"),
        .package(path: "../NeechanMedia"),
        .package(path: "../NeechanSettings"),
        .package(path: "../NeechanTestSupport")
    ],
    targets: [
        .target(
            name: "NeechanUI",
            dependencies: ["NeechanCore", "NeechanMedia", "NeechanSettings"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeechanUIUnitTests",
            dependencies: [
                "NeechanUI",
                "NeechanTestSupport",
                .product(name: "NeechanAPITesting", package: "NeechanAPI"),
            ],
            path: "Tests/NeechanUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
