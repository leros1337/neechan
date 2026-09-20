import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale
import Testing
@testable import NeechanMedia

/// That the FFmpeg the app links is the one it expects.
///
/// The build is this project's own and deliberately trimmed, so a codec left
/// out of it does not fail to compile: it fails when a reader opens a file,
/// as a clip that will not play. These assertions are what turn that into a
/// failing test instead.
///
/// They also pin the major version. Moving between FFmpeg releases has already
/// changed a type from opaque to concrete and renamed a constant, so a build
/// that quietly went backwards is worth catching here rather than in a crash.
@Suite("The FFmpeg build")
struct FFmpegBuildTests {
    /// FFmpeg 9 ships libavcodec 63. Anything older is a different build than
    /// the one this code was written against.
    @Test("the libraries are at least the versions the app was built against")
    func versionsAreCurrent() {
        #expect(avcodec_version() >> 16 >= 63, "libavcodec is older than FFmpeg 9")
        #expect(avformat_version() >> 16 >= 63, "libavformat is older than FFmpeg 9")
        #expect(avutil_version() >> 16 >= 61, "libavutil is older than FFmpeg 9")
        #expect(swresample_version() >> 16 >= 7)
        #expect(swscale_version() >> 16 >= 10)
    }

    /// Everything a board or a Matroska file can hand the app.
    @Test(
        "every codec the app opens files with is in the build",
        arguments: [
            AV_CODEC_ID_VP8, AV_CODEC_ID_VP9, AV_CODEC_ID_AV1,
            AV_CODEC_ID_H264, AV_CODEC_ID_HEVC,
            AV_CODEC_ID_VORBIS, AV_CODEC_ID_OPUS, AV_CODEC_ID_AAC,
            AV_CODEC_ID_MP3, AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC,
            AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_DTS
        ]
    )
    func decodersArePresent(codecID: AVCodecID) {
        #expect(avcodec_find_decoder(codecID) != nil, "no decoder for codec \(codecID.rawValue)")
    }

    /// What the WebM converter writes with. The H.264 one is VideoToolbox's,
    /// which is why this build needs no GPL encoder.
    @Test("the converter's encoders are in the build")
    func encodersArePresent() {
        #expect(
            avcodec_find_encoder_by_name("h264_videotoolbox") != nil,
            "the hardware H.264 encoder is missing, so saving a WebM would fail"
        )
        #expect(avcodec_find_encoder(AV_CODEC_ID_AAC) != nil)
    }

    @Test("the containers the app reads and writes are in the build")
    func containersArePresent() {
        #expect(av_find_input_format("matroska") != nil, "no Matroska demuxer, so no WebM or MKV")
        #expect(av_find_input_format("mov") != nil, "no MOV demuxer, so no MP4")
        #expect(av_guess_format("mp4", nil, nil) != nil, "no MP4 muxer, so nothing to convert into")
    }

    @Test("VideoToolbox is available to the decoders")
    func hardwareIsAvailable() {
        #expect(
            av_hwdevice_find_type_by_name("videotoolbox") != AV_HWDEVICE_TYPE_NONE,
            "this build cannot use the graphics hardware at all"
        )
    }

    /// The whole point of building it ourselves. A GPL component creeping back
    /// in would change what the app may be licensed as, silently.
    @Test("nothing GPL was linked in")
    func theBuildIsNotGPL() {
        let configuration = String(cString: avcodec_configuration())
        #expect(!configuration.contains("--enable-gpl"), "the FFmpeg build is GPL again")
        #expect(!configuration.contains("--enable-nonfree"))
        #expect(!configuration.contains("--enable-version3"))
    }
}
