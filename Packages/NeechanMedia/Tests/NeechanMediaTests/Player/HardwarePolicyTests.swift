import Foundation
import Libavcodec
import Testing
@testable import NeechanMedia

/// Which streams are handed to VideoToolbox.
///
/// Getting this wrong in the permissive direction is the expensive one: the
/// hwaccel fails, no frame is produced, and the reader is shown a clip that
/// sits there rather than an error.
@Suite("Hardware decoding eligibility")
struct HardwarePolicyTests {
    private let withVP9 = VideoDecoderCapabilities(hasVP9Hardware: true, hasAV1Hardware: true)
    private let withoutVP9 = VideoDecoderCapabilities(hasVP9Hardware: false, hasAV1Hardware: false)

    @Test("H.264 and HEVC always go to VideoToolbox")
    func h264AndHEVCAlwaysQualify() {
        for capabilities in [withVP9, withoutVP9] {
            #expect(HardwarePolicy.wantsVideoToolbox(
                codecID: AV_CODEC_ID_H264, profile: 100, capabilities: capabilities
            ))
            #expect(HardwarePolicy.wantsVideoToolbox(
                codecID: AV_CODEC_ID_HEVC, profile: 1, capabilities: capabilities
            ))
        }
    }

    @Test("VP9 needs both the device and a profile Apple decodes")
    func vp9NeedsBoth() {
        // Profile 0 is 8-bit 4:2:0 and profile 2 is 10-bit: both are taken.
        #expect(HardwarePolicy.wantsVideoToolbox(codecID: AV_CODEC_ID_VP9, profile: 0, capabilities: withVP9))
        #expect(HardwarePolicy.wantsVideoToolbox(codecID: AV_CODEC_ID_VP9, profile: 2, capabilities: withVP9))

        // Profiles 1 and 3 are 4:2:2 and 4:4:4, which no Apple decoder has.
        #expect(!HardwarePolicy.wantsVideoToolbox(codecID: AV_CODEC_ID_VP9, profile: 1, capabilities: withVP9))
        #expect(!HardwarePolicy.wantsVideoToolbox(codecID: AV_CODEC_ID_VP9, profile: 3, capabilities: withVP9))

        // And a device without the decoder takes none of them.
        #expect(!HardwarePolicy.wantsVideoToolbox(codecID: AV_CODEC_ID_VP9, profile: 0, capabilities: withoutVP9))
    }

    /// Better a warm phone on a rare file than a clip that never starts.
    @Test("an unknown profile is decoded in software")
    func unknownProfilesStaySoft() {
        #expect(!HardwarePolicy.wantsVideoToolbox(
            codecID: AV_CODEC_ID_VP9, profile: AV_PROFILE_UNKNOWN, capabilities: withVP9
        ))
    }

    @Test("VP8 is never decoded in hardware, because nothing decodes it")
    func vp8NeverQualifies() {
        #expect(!HardwarePolicy.wantsVideoToolbox(
            codecID: AV_CODEC_ID_VP8, profile: 0, capabilities: withVP9
        ))
    }

    /// Rare in a .webm and common in a .mkv, which the app also opens.
    @Test("AV1 goes to VideoToolbox where the device has a decoder")
    func av1FollowsTheDevice() {
        #expect(HardwarePolicy.wantsVideoToolbox(
            codecID: AV_CODEC_ID_AV1, profile: 0, capabilities: withVP9
        ))
        #expect(!HardwarePolicy.wantsVideoToolbox(
            codecID: AV_CODEC_ID_AV1, profile: 0, capabilities: withoutVP9
        ))
        // Profile 0 is the only one Apple decodes, and the only one written.
        #expect(!HardwarePolicy.wantsVideoToolbox(
            codecID: AV_CODEC_ID_AV1, profile: 1, capabilities: withVP9
        ))
    }

    @Test("a codec the app never meets is not guessed at")
    func unknownCodecsStaySoft() {
        #expect(!HardwarePolicy.wantsVideoToolbox(
            codecID: AV_CODEC_ID_THEORA, profile: 0, capabilities: withVP9
        ))
        #expect(!HardwarePolicy.wantsVideoToolbox(
            codecID: AV_CODEC_ID_MPEG4, profile: 0, capabilities: withVP9
        ))
    }
}
