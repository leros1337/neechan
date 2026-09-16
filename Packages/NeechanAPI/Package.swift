// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeechanAPI",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NeechanAPI", targets: ["NeechanAPI"]),
        // Test-only helpers (fake transport, request recording). Shipped as a
        // normal product so other packages' test targets can use it.
        .library(name: "NeechanAPITesting", targets: ["NeechanAPITesting"])
    ],
    dependencies: [
        .package(path: "../NeechanTestSupport")
    ],
    targets: [
        .target(
            name: "NeechanAPI",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NeechanAPITesting",
            dependencies: ["NeechanAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeechanAPITests",
            dependencies: ["NeechanAPI", "NeechanAPITesting", "NeechanTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
