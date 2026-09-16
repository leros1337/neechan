// swift-tools-version: 6.2
import PackageDescription

// WebM (VP8/VP9 with Vorbis or Opus) cannot be opened by AVFoundation at all,
// so video goes through KSPlayer, which wraps kingslay/FFmpegKit. That checkout
// vendors prebuilt xcframeworks and is several gigabytes once cloned, and it is
// GPL-3.0, which is why this project is too.
//
// Only this package may import KSPlayer. Everything above it sees
// `MediaPlayerView` and knows nothing about the engine underneath.
let package = Package(
    name: "NeechanMedia",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NeechanMedia", targets: ["NeechanMedia"])
    ],
    dependencies: [
        .package(path: "../NeechanAPI"),
        .package(path: "../NeechanSettings"),
        .package(path: "../NeechanTestSupport"),
        .package(url: "https://github.com/kingslay/KSPlayer.git", from: "2.3.4"),
        // Already in the graph as KSPlayer's own dependency, at the same pin.
        // Named here because the WebM converter uses the libraries directly:
        // playback goes through KSPlayer, but a transcode has no player in it.
        .package(url: "https://github.com/kingslay/FFmpegKit.git", from: "6.1.4")
    ],
    targets: [
        .target(
            name: "NeechanMedia",
            dependencies: [
                "NeechanAPI",
                "NeechanSettings",
                .product(name: "KSPlayer", package: "KSPlayer"),
                .product(name: "Libavcodec", package: "FFmpegKit"),
                .product(name: "Libavformat", package: "FFmpegKit"),
                .product(name: "Libavutil", package: "FFmpegKit"),
                .product(name: "Libswresample", package: "FFmpegKit"),
                .product(name: "Libswscale", package: "FFmpegKit")
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeechanMediaTests",
            dependencies: ["NeechanMedia", "NeechanTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
