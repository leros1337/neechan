import Foundation
import Libavcodec

/// Whether a stream should be handed to VideoToolbox.
///
/// Asking for hardware where there is none does not fail cleanly: the hwaccel
/// setup fails, the decoder produces no frame, and what the reader sees is a
/// clip that never starts. So the question is answered before the file is
/// opened, from what the device says it has and what is actually in the
/// stream, rather than left to be discovered.
enum HardwarePolicy {
    /// VP9 profiles VideoToolbox will take: 0 is 8-bit 4:2:0, 2 is 10-bit.
    ///
    /// Profiles 1 and 3 are 4:2:2 and 4:4:4, which no Apple decoder handles.
    /// They are rare on imageboards and decode in software perfectly well.
    static let hardwareVP9Profiles: Set<Int32> = [0, 2]

    /// - Parameters:
    ///   - codecID: what the stream holds.
    ///   - profile: the stream's profile, or `AV_PROFILE_UNKNOWN` when the
    ///     demuxer could not say.
    ///   - capabilities: what this device has.
    static func wantsVideoToolbox(
        codecID: AVCodecID,
        profile: Int32,
        capabilities: VideoDecoderCapabilities
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC:
            // Every device the app runs on decodes both, and HEVC carried in
            // an MP4 tagged `hev1` is exactly what the boards serve.
            return true
        case AV_CODEC_ID_VP9:
            // An unknown profile is treated as one VideoToolbox cannot take.
            // Guessing wrong the other way costs a clip that never starts;
            // guessing wrong this way costs some battery on a rare file.
            return capabilities.hasVP9Hardware && hardwareVP9Profiles.contains(profile)
        case AV_CODEC_ID_AV1:
            // Rare in a .webm and common in a .mkv. Decoding it in software is
            // slow enough to drop frames on a phone, so the hardware path is
            // worth taking wherever it exists. Profile 0 is the only one Apple
            // decodes, and the only one anything writes.
            return capabilities.hasAV1Hardware && profile == 0
        default:
            // VP8 among them: no Apple decoder has ever existed for it.
            return false
        }
    }
}
