import Foundation
import VideoToolbox

/// Which video codecs this device can decode in hardware.
///
/// Asked once and kept, because the answer cannot change while the app runs.
///
/// Only VP9 and AV1 are worth asking about. H.264 and HEVC have had a
/// VideoToolbox decoder on every device the app runs on, and VP8 has never had
/// one anywhere. The other two depend on which phone this is: VP9 arrived with
/// the A14 and AV1 later still, the simulator has neither, and a clip decoded
/// in software costs a full core and a warm phone for its whole length.
public struct VideoDecoderCapabilities: Sendable, Equatable {
    /// True when VideoToolbox has a VP9 decoder here.
    public var hasVP9Hardware: Bool
    /// True when it has an AV1 decoder, which a Matroska file may well need.
    public var hasAV1Hardware: Bool

    public init(hasVP9Hardware: Bool, hasAV1Hardware: Bool = false) {
        self.hasVP9Hardware = hasVP9Hardware
        self.hasAV1Hardware = hasAV1Hardware
    }

    /// What this device can do.
    public static let current = probe()

    /// Asks VideoToolbox what it has.
    ///
    /// - Parameter isForcedToSoftware: answer as a device with no VP9 decoder
    ///   would, whatever this one has. Set from the environment so the two
    ///   paths can be compared on one phone.
    static func probe(
        isForcedToSoftware: Bool = isForcedToSoftwareByEnvironment
    ) -> VideoDecoderCapabilities {
        guard !isForcedToSoftware else {
            return VideoDecoderCapabilities(hasVP9Hardware: false, hasAV1Hardware: false)
        }

        #if os(macOS)
        // On a Mac these are supplemental decoders, and one has to be
        // registered before it will be reported or used. iOS has no such call
        // and needs none.
        if #available(macOS 11.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        #endif

        return VideoDecoderCapabilities(
            hasVP9Hardware: VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9),
            hasAV1Hardware: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        )
    }

    /// `NEECHAN_FORCE_SOFTWARE_VP9=1` in the scheme, for comparing the two
    /// paths on a device that has the decoder.
    static var isForcedToSoftwareByEnvironment: Bool {
        ProcessInfo.processInfo.environment["NEECHAN_FORCE_SOFTWARE_VP9"] == "1"
    }
}
