// swift-tools-version: 6.2
import PackageDescription

// Shared test fixtures (recorded 2ch responses) plus a loader.
// Intentionally has NO package dependencies so every other package's test
// target can depend on it without creating a dependency cycle.
let package = Package(
    name: "NeechanTestSupport",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NeechanTestSupport", targets: ["NeechanTestSupport"])
    ],
    targets: [
        .target(
            name: "NeechanTestSupport",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeechanTestSupportTests",
            dependencies: ["NeechanTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
