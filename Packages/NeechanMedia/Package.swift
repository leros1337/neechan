// swift-tools-version: 6.2
import PackageDescription

// WebM (VP8/VP9 with Vorbis or Opus) cannot be opened by AVFoundation at all,
// and neither can the `hev1`-tagged HEVC the boards serve in MP4, so video is
// decoded by FFmpeg whatever the container. VideoToolbox does the work
// wherever the device has a decoder for what is in the file.
//
// The FFmpeg build is this project's own: trimmed to the containers and codecs
// an imageboard actually serves, and configured without a single GPL
// component, which is what lets the app be MIT. See the neechan-ffmpeg
// repository for the configure line and how to rebuild it.
//
// Only this package may import the FFmpeg modules. Everything above it sees
// `MediaPlayerView` and knows nothing about what is underneath.
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
        .package(url: "https://github.com/leros1337/neechan-ffmpeg.git", from: "9.0.2")
    ],
    targets: [
        .target(
            name: "NeechanMedia",
            dependencies: [
                "NeechanAPI",
                "NeechanSettings",
                .product(name: "FFmpeg", package: "neechan-ffmpeg")
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
