// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeechanSettings",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NeechanSettings", targets: ["NeechanSettings"])
    ],
    dependencies: [
        .package(path: "../NeechanAPI"),
        .package(path: "../NeechanTestSupport")
    ],
    targets: [
        .target(
            name: "NeechanSettings",
            dependencies: ["NeechanAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeechanSettingsTests",
            dependencies: ["NeechanSettings", "NeechanTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
