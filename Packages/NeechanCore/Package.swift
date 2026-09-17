// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeechanCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NeechanCore", targets: ["NeechanCore"])
    ],
    dependencies: [
        .package(path: "../NeechanAPI"),
        .package(path: "../NeechanSettings"),
        .package(path: "../NeechanTestSupport")
    ],
    targets: [
        .target(
            name: "NeechanCore",
            dependencies: ["NeechanAPI", "NeechanSettings"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeechanCoreTests",
            dependencies: [
                "NeechanCore",
                "NeechanTestSupport",
                .product(name: "NeechanAPITesting", package: "NeechanAPI")
            ],
            // Copied rather than processed: one of them is a SwiftData store
            // written by the old schema, and it has to arrive byte for byte.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
