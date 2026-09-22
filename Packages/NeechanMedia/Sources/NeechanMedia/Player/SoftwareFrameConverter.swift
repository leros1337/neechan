import CoreMedia
import CoreVideo
import Foundation
import Libavutil
import Libswscale

/// Turns a picture the CPU decoded into one the display layer can show.
///
/// Hardware frames arrive as pixel buffers already and never come here. These
/// are the rest: VP8, VP9 in a profile Apple does not decode, anything at all
/// on a device without the right decoder.
///
/// Everything is converted to two-plane NV12, which is also what VideoToolbox
/// hands back, so nothing downstream has to know which path a frame took. For
/// the common 8-bit 4:2:0 source that is an interleave of the two chroma
/// planes and nothing more.
final class SoftwareFrameConverter {
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var pool: CVPixelBufferPool?
    private var poolWidth: Int32 = 0
    private var poolHeight: Int32 = 0
    private var poolFormat: OSType = 0

    deinit {
        close()
    }

    func close() {
        if let scaler {
            sws_freeContext(scaler)
            self.scaler = nil
        }
        pool = nil
    }

    func pixelBuffer(from frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = frame.pointee.width
        let height = frame.pointee.height
        guard width > 0, height > 0 else { return nil }

        let isFullRange = frame.pointee.color_range == AVCOL_RANGE_JPEG
        let format: OSType = isFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        guard let pool = pool(width: width, height: height, format: format),
              let buffer = makeBuffer(from: pool)
        else { return nil }

        scaler = sws_getCachedContext(
            scaler,
            width, height, AVPixelFormat(rawValue: frame.pointee.format),
            width, height, AV_PIX_FMT_NV12,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard let scaler else { return nil }

        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        var destination: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil
        ]
        var destinationStrides: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)),
            0, 0
        ]

        var sourceData = frame.pointee.data
        var sourceStrides = frame.pointee.linesize
        let scaled = withUnsafePointer(to: &sourceData) { data in
            data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { source in
                withUnsafePointer(to: &sourceStrides) { strides in
                    strides.withMemoryRebound(to: Int32.self, capacity: 8) { sourceStride in
                        sws_scale(
                            scaler, source, sourceStride, 0, height,
                            &destination, &destinationStrides
                        )
                    }
                }
            }
        }
        guard scaled > 0 else { return nil }

        attachColour(to: buffer, from: frame, isFullRange: isFullRange)
        return buffer
    }

    /// A pool for this size and format, made again when either changes.
    ///
    /// Frames are the same shape for the length of a clip, so the buffers are
    /// worth reusing: a phone showing thirty of them a second would otherwise
    /// allocate and free tens of megabytes every second for no reason.
    private func pool(width: Int32, height: Int32, format: OSType) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height, poolFormat == format {
            return pool
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: Int(width),
            kCVPixelBufferHeightKey: Int(height),
            // Wanted by everything that draws: the display layer, and a Metal
            // renderer if one is ever put behind it.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]

        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &created
        ) == kCVReturnSuccess else { return nil }

        pool = created
        poolWidth = width
        poolHeight = height
        poolFormat = format
        return created
    }

    private func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Tells the renderer how to read the colours.
    ///
    /// Without this a clip is rendered with whatever the layer assumes, and
    /// the usual symptom is washed-out or oversaturated colour rather than
    /// anything that looks like a bug.
    private func attachColour(
        to buffer: CVPixelBuffer, from frame: UnsafeMutablePointer<AVFrame>, isFullRange: Bool
    ) {
        let matrix: CFString? = switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: nil
        }
        let primaries: CFString? = switch frame.pointee.color_primaries {
        case AVCOL_PRI_BT709: kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT470BG: kCVImageBufferColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M: kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT2020: kCVImageBufferColorPrimaries_ITU_R_2020
        default: nil
        }
        let transfer: CFString? = switch frame.pointee.color_trc {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M: kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12: kCVImageBufferTransferFunction_ITU_R_2020
        case AVCOL_TRC_SMPTEST2084: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        default: nil
        }

        // Most WebM files say nothing about their colour, and Rec. 709 is what
        // everything that wrote them assumed.
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey,
            matrix ?? kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey,
            primaries ?? kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey,
            transfer ?? kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate
        )
        if isFullRange {
            CVBufferSetAttachment(
                buffer, kCMFormatDescriptionExtension_FullRangeVideo,
                kCFBooleanTrue, .shouldPropagate
            )
        }
    }
}
