import Foundation
import os

/// What the player says about itself.
///
/// Off the critical path and cheap when nobody is listening, so it can stay in
/// the shipping build: a clip that stops halfway through only ever does it on
/// somebody's phone, on their network, and without this there is nothing to
/// look at afterwards.
///
/// Watch it with:
///
///     xcrun simctl spawn booted log stream \
///         --predicate 'subsystem == "io.neechan.media"' --level debug
extension Duration {
    /// Seconds as a number, for logging.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

enum MediaLog {
    /// Reading bytes, whether from the network or a file.
    static let reader = Logger(subsystem: "io.neechan.media", category: "reader")
    /// Opening files and handing out packets.
    static let demuxer = Logger(subsystem: "io.neechan.media", category: "demuxer")
    /// Turning packets into pictures and sound.
    static let decoder = Logger(subsystem: "io.neechan.media", category: "decoder")
    /// The clock, the renderers, and how playback ends.
    static let output = Logger(subsystem: "io.neechan.media", category: "output")
    /// What the app above is told.
    static let player = Logger(subsystem: "io.neechan.media", category: "player")
}
