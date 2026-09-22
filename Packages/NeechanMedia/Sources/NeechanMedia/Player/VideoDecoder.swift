import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale

/// A decoded picture, ready to be shown.
struct DecodedFrame: QueuedMedia, @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentation: CMTime
    let duration: CMTime
    /// What the queue's generation was when this was decoded, so a frame for
    /// the position before a seek can be recognised and dropped.
    let generation: Int

    var mediaDuration: Double {
        duration.isValid ? TimeMath.seconds(duration) : 0
    }

    /// Roughly what the picture costs to keep.
    var byteCount: Int {
        CVPixelBufferGetDataSize(pixelBuffer)
    }
}

/// Decodes video, in hardware where the device can.
///
/// The decoding itself is FFmpeg's, with VideoToolbox underneath it wherever
/// the device has a decoder for what is in the file. Letting FFmpeg drive
/// VideoToolbox rather than driving it directly is what makes the awkward
/// cases work without a line of code here: parameter sets carried in-band by
/// the `hev1` HEVC the boards serve, frames arriving out of display order in
/// an H.264 file with B-frames, and the format descriptions each codec needs.
///
/// Lives on the decoding thread and is touched from nowhere else.
final class VideoDecoder: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noDecoder(AVCodecID)
        case cannotOpen(Int32)

        var description: String {
            switch self {
            case .noDecoder: "This video is in a format the app cannot decode."
            case .cannotOpen(let code): "The video could not be decoded (\(FFmpegStatus.message(code)))."
            }
        }
    }

    /// Whether VideoToolbox was asked for. What actually happened is
    /// `isDecodingInHardware`, which only the first frame can answer.
    let wantsHardware: Bool
    /// True once a frame has come back from VideoToolbox rather than the CPU.
    private(set) var isDecodingInHardware = false
    /// So the fallback is mentioned once rather than for every picture.
    private var hasReportedSoftwareFallback = false

    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var hardwareDevice: UnsafeMutablePointer<AVBufferRef>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private let timeBase: AVRational
    private let frameRate: AVRational
    private let converter = SoftwareFrameConverter()

    init(
        stream: UnsafeMutablePointer<AVStream>,
        capabilities: VideoDecoderCapabilities = .current
    ) throws {
        let parameters = stream.pointee.codecpar!
        timeBase = stream.pointee.time_base
        frameRate = stream.pointee.avg_frame_rate

        wantsHardware = HardwarePolicy.wantsVideoToolbox(
            codecID: parameters.pointee.codec_id,
            profile: parameters.pointee.profile,
            capabilities: capabilities
        )

        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw Failure.noDecoder(parameters.pointee.codec_id)
        }
        guard let context = avcodec_alloc_context3(codec) else {
            throw Failure.cannotOpen(0)
        }
        self.context = context

        let copied = avcodec_parameters_to_context(context, parameters)
        guard copied >= 0 else { throw Failure.cannotOpen(copied) }

        // Without this the decoder has no idea what its timestamps mean, and
        // anything derived from them inside it comes out wrong.
        context.pointee.pkt_timebase = timeBase
        // Let FFmpeg pick a thread count from the machine. Only used when the
        // decoding is done on the CPU.
        context.pointee.thread_count = 0
        context.pointee.thread_type = Int32(FF_THREAD_FRAME | FF_THREAD_SLICE)

        if wantsHardware {
            var device: UnsafeMutablePointer<AVBufferRef>?
            let created = av_hwdevice_ctx_create(
                &device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0
            )
            if created >= 0, let device {
                hardwareDevice = device
                context.pointee.hw_device_ctx = av_buffer_ref(device)
                // Installed only when hardware was asked for, so it can accept
                // VideoToolbox without asking again whether it should. If the
                // hwaccel then fails to start, FFmpeg asks a second time with
                // VideoToolbox taken off the list and this hands back the
                // software format instead, which is the fallback that keeps a
                // wrong guess from becoming a clip that never starts.
                context.pointee.get_format = chooseVideoToolbox
            }
        }

        let opened = avcodec_open2(context, codec, nil)
        guard opened >= 0 else { throw Failure.cannotOpen(opened) }

        MediaLog.decoder.debug(
            """
            video: \(String(cString: codec.pointee.name), privacy: .public) \
            profile \(parameters.pointee.profile, privacy: .public), \
            \(parameters.pointee.width, privacy: .public)x\(parameters.pointee.height, privacy: .public), \
            \(self.frameRate.den > 0 ? Double(self.frameRate.num) / Double(self.frameRate.den) : 0, format: .fixed(precision: 1), privacy: .public) fps, \
            \(parameters.pointee.bit_rate / 1000, privacy: .public) kbps, \
            asked for \(self.wantsHardware ? "hardware" : "software", privacy: .public)
            """
        )

        frame = av_frame_alloc()
    }

    deinit {
        close()
    }

    func close() {
        if context != nil {
            var owned: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&owned)
            context = nil
        }
        if hardwareDevice != nil {
            var owned: UnsafeMutablePointer<AVBufferRef>? = hardwareDevice
            av_buffer_unref(&owned)
            hardwareDevice = nil
        }
        if frame != nil {
            var owned: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&owned)
            frame = nil
        }
        converter.close()
    }

    /// Decodes one packet, handing every picture it yields to `output`.
    ///
    /// A packet usually makes one picture, sometimes none, and occasionally
    /// several, which is why this reports through a closure rather than
    /// returning.
    func decode(
        _ packet: OwnedPacket?, generation: Int, output: (DecodedFrame) -> Void
    ) throws {
        guard let context, let frame else { return }

        // A nil packet drains the decoder, which is how the last few frames of
        // a reordered stream come out at the end of a file.
        let sent = avcodec_send_packet(context, packet?.packet)
        guard sent >= 0 || sent == FFmpegStatus.tryAgain || sent == FFmpegStatus.endOfFile else {
            throw Failure.cannotOpen(sent)
        }

        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == FFmpegStatus.tryAgain || received == FFmpegStatus.endOfFile {
                return
            }
            guard received >= 0 else { throw Failure.cannotOpen(received) }
            defer { av_frame_unref(frame) }

            if let decoded = makeFrame(from: frame, generation: generation) {
                output(decoded)
            }
        }
    }

    /// Throws away everything the decoder is holding, after a seek.
    func flush() {
        guard let context else { return }
        avcodec_flush_buffers(context)
    }

    private func makeFrame(
        from frame: UnsafeMutablePointer<AVFrame>, generation: Int
    ) -> DecodedFrame? {
        let pixelBuffer: CVPixelBuffer?
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // A hardware frame already is a pixel buffer: the fourth data
            // pointer is the CVPixelBuffer itself, so nothing is copied.
            if !isDecodingInHardware {
                MediaLog.decoder.debug("decoding in hardware")
            }
            isDecodingInHardware = true
            pixelBuffer = frame.pointee.data.3.map {
                Unmanaged<CVPixelBuffer>.fromOpaque($0).takeUnretainedValue()
            }
        } else {
            if wantsHardware, !hasReportedSoftwareFallback {
                hasReportedSoftwareFallback = true
                let format = av_get_pix_fmt_name(AVPixelFormat(rawValue: frame.pointee.format))
                    .map { String(cString: $0) } ?? "an unnamed format"
                MediaLog.decoder.debug(
                    "hardware was asked for and refused; decoding on the CPU as \(format, privacy: .public)"
                )
            }
            pixelBuffer = converter.pixelBuffer(from: frame)
        }
        guard let pixelBuffer else { return nil }

        let presentation = TimeMath.presentation(
            pts: frame.pointee.best_effort_timestamp,
            dts: frame.pointee.pkt_dts,
            numerator: timeBase.num,
            denominator: timeBase.den
        )
        let duration = TimeMath.duration(
            packetDuration: frame.pointee.duration,
            numerator: timeBase.num,
            denominator: timeBase.den,
            frameRateNumerator: frameRate.num,
            frameRateDenominator: frameRate.den
        )
        return DecodedFrame(
            pixelBuffer: pixelBuffer,
            presentation: presentation,
            duration: duration,
            generation: generation
        )
    }
}

private let chooseVideoToolbox: @convention(c) (
    UnsafeMutablePointer<AVCodecContext>?, UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat = { _, formats in
    guard let formats else { return AV_PIX_FMT_NONE }
    var index = 0
    while formats[index] != AV_PIX_FMT_NONE {
        if formats[index] == AV_PIX_FMT_VIDEOTOOLBOX { return formats[index] }
        index += 1
    }
    // FFmpeg puts the format it would use itself first, so this is the
    // software path, taken when VideoToolbox was not offered or has just been
    // withdrawn after failing to start.
    return formats[0]
}
