import AudioToolbox
import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// A run of decoded sound, ready to be played.
struct DecodedAudio: QueuedMedia, @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let presentation: CMTime
    let generation: Int
    let mediaDuration: Double
    let byteCount: Int
}

/// Decodes sound and hands it over as something the renderer will take.
///
/// Always comes out as interleaved 32-bit float at the source's own sample
/// rate, in mono or stereo, whatever went in. Keeping the rate means no
/// resampling and no drift; folding anything wider down to stereo is what a
/// phone can play anyway.
///
/// The source's rate and channels are taken from the first frame decoded, not
/// from the file's header, because the header can be wrong. HE-AAC v2 often
/// declares only its core, 22.05 kHz mono, and becomes 44.1 kHz stereo once
/// the decoder finds the rest inside the first packet. Built from the header,
/// every run after that was refused and the clip played in silence. Should
/// the sound change shape again later, the converter is rebuilt for it and
/// what the renderer is given stays the same.
///
/// Opus and Vorbis both begin with samples that exist only to prime the
/// decoder and must not be heard. libavcodec trims them itself, which is why
/// there is nothing here about it.
///
/// Each run is played where the one before it ended, not where the container
/// stamped it; `AudioTimeline` says why.
final class AudioDecoder: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noDecoder(AVCodecID)
        case cannotOpen(Int32)

        var description: String {
            switch self {
            case .noDecoder: "This audio is in a format the app cannot decode."
            case .cannotOpen(let code): "The audio could not be decoded (\(FFmpegStatus.message(code)))."
            }
        }
    }

    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var resampled: UnsafeMutablePointer<AVFrame>?
    private var formatDescription: CMAudioFormatDescription?
    private let timeBase: AVRational
    private var timeline: AudioTimeline

    private(set) var sampleRate: Int32 = 48_000
    private(set) var channelCount: Int32 = 2

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        let parameters = stream.pointee.codecpar!
        timeBase = stream.pointee.time_base
        timeline = AudioTimeline(sampleRate: 48_000)

        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw Failure.noDecoder(parameters.pointee.codec_id)
        }
        guard let context = avcodec_alloc_context3(codec) else {
            throw Failure.cannotOpen(0)
        }
        self.context = context

        let copied = avcodec_parameters_to_context(context, parameters)
        guard copied >= 0 else { throw Failure.cannotOpen(copied) }
        context.pointee.pkt_timebase = timeBase

        let opened = avcodec_open2(context, codec, nil)
        guard opened >= 0 else { throw Failure.cannotOpen(opened) }

        // What the header says, until the first frame says otherwise.
        sampleRate = context.pointee.sample_rate > 0 ? context.pointee.sample_rate : 48_000
        channelCount = min(2, max(1, context.pointee.ch_layout.nb_channels))
        timeline = AudioTimeline(sampleRate: sampleRate)

        MediaLog.decoder.debug(
            """
            audio: \(String(cString: codec.pointee.name), privacy: .public), \
            \(self.sampleRate, privacy: .public) Hz, \
            \(self.channelCount, privacy: .public) ch by its header
            """
        )

        frame = av_frame_alloc()
        resampled = av_frame_alloc()
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
        if resampler != nil {
            var owned = resampler
            swr_free(&owned)
            resampler = nil
        }
        for held in [frame, resampled] where held != nil {
            var owned: UnsafeMutablePointer<AVFrame>? = held
            av_frame_free(&owned)
        }
        frame = nil
        resampled = nil
    }

    /// Decodes one packet, handing over every run of sound it yields.
    func decode(
        _ packet: OwnedPacket?, generation: Int, output: (DecodedAudio) -> Void
    ) throws {
        guard let context, let frame else { return }

        let sent = avcodec_send_packet(context, packet?.packet)
        guard sent >= 0 || sent == FFmpegStatus.tryAgain || sent == FFmpegStatus.endOfFile else {
            throw Failure.cannotOpen(sent)
        }

        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == FFmpegStatus.tryAgain || received == FFmpegStatus.endOfFile { return }
            guard received >= 0 else { throw Failure.cannotOpen(received) }
            defer { av_frame_unref(frame) }

            if let decoded = makeAudio(from: frame, generation: generation) {
                output(decoded)
            }
        }
    }

    func flush() {
        guard let context else { return }
        avcodec_flush_buffers(context)
        timeline.reset()
    }

    /// Settles what the renderer will be given, from the first frame decoded.
    ///
    /// Once only. Everything after is converted to this, so the renderer and
    /// the timeline never see the sound change shape.
    private func settleOutput(on frame: UnsafeMutablePointer<AVFrame>) {
        let rate = frame.pointee.sample_rate > 0 ? frame.pointee.sample_rate : sampleRate
        let channels = min(2, max(1, frame.pointee.ch_layout.nb_channels))
        if rate != sampleRate || channels != channelCount {
            MediaLog.decoder.debug(
                """
                audio is \(rate, privacy: .public) Hz, \(frame.pointee.ch_layout.nb_channels, privacy: .public) ch, \
                not the \(self.sampleRate, privacy: .public) Hz, \(self.channelCount, privacy: .public) ch \
                its header said; playing what it is
                """
            )
        }
        sampleRate = rate
        channelCount = channels
        timeline = AudioTimeline(sampleRate: rate)
        formatDescription = makeFormatDescription()
    }

    /// A converter from `frame`'s shape to the settled output.
    ///
    /// Built from the frame rather than the decoder, which is only as right as
    /// the header it read.
    private func makeResampler(for frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if resampler != nil {
            var owned = resampler
            swr_free(&owned)
            resampler = nil
        }

        var output = AVChannelLayout()
        av_channel_layout_default(&output, channelCount)
        defer { av_channel_layout_uninit(&output) }

        var created: OpaquePointer?
        let result = swr_alloc_set_opts2(
            &created,
            &output, AV_SAMPLE_FMT_FLT, sampleRate,
            &frame.pointee.ch_layout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate,
            0, nil
        )
        guard result >= 0, let created, swr_init(created) >= 0 else {
            var owned = created
            swr_free(&owned)
            return false
        }
        resampler = created
        return true
    }

    /// Said once per decoder, so a clip that has gone silent says why without
    /// saying it fifty times a second.
    private var hasReportedRefusal = false

    private func reportRefusal(_ code: Int32, of frame: UnsafeMutablePointer<AVFrame>) {
        guard !hasReportedRefusal else { return }
        hasReportedRefusal = true
        MediaLog.decoder.error(
            """
            the sound cannot be converted for playing \
            (\(frame.pointee.sample_rate, privacy: .public) Hz, \
            \(frame.pointee.ch_layout.nb_channels, privacy: .public) ch: \
            \(FFmpegStatus.message(code), privacy: .public)); the clip will be silent
            """
        )
    }

    /// Converts `frame` into `resampled`, building or rebuilding the converter
    /// when the frame is a shape it was not built for.
    private func convert(
        _ frame: UnsafeMutablePointer<AVFrame>, into resampled: UnsafeMutablePointer<AVFrame>
    ) -> Bool {
        if resampler == nil {
            guard makeResampler(for: frame) else {
                reportRefusal(0, of: frame)
                return false
            }
        }
        var result = swr_convert_frame(resampler, resampled, frame)
        if result == FFmpegStatus.inputChanged {
            MediaLog.decoder.debug(
                """
                the sound changed shape midway, to \(frame.pointee.sample_rate, privacy: .public) Hz, \
                \(frame.pointee.ch_layout.nb_channels, privacy: .public) ch; converting it to what it was
                """
            )
            guard makeResampler(for: frame) else {
                reportRefusal(result, of: frame)
                return false
            }
            result = swr_convert_frame(resampler, resampled, frame)
        }
        guard result >= 0 else {
            reportRefusal(result, of: frame)
            return false
        }
        return true
    }

    /// Interleaved 32-bit float, which is what the renderer is handed.
    private func makeFormatDescription() -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var created: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &created
        ) == noErr else { return nil }
        return created
    }

    private func makeAudio(
        from frame: UnsafeMutablePointer<AVFrame>, generation: Int
    ) -> DecodedAudio? {
        guard let resampled else { return nil }
        if formatDescription == nil { settleOutput(on: frame) }
        guard let formatDescription else { return nil }

        av_frame_unref(resampled)
        resampled.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        resampled.pointee.sample_rate = sampleRate
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, channelCount)
        av_channel_layout_copy(&resampled.pointee.ch_layout, &layout)
        av_channel_layout_uninit(&layout)

        guard convert(frame, into: resampled) else { return nil }
        let sampleCount = resampled.pointee.nb_samples
        guard sampleCount > 0, let data = resampled.pointee.data.0 else { return nil }

        let bytes = Int(sampleCount) * Int(channelCount) * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }

        guard CMBlockBufferReplaceDataBytes(
            with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes
        ) == noErr else { return nil }

        let presentation = timeline.place(
            TimeMath.presentation(
                pts: frame.pointee.best_effort_timestamp,
                dts: frame.pointee.pkt_dts,
                numerator: timeBase.num,
                denominator: timeBase.den
            ),
            sampleCount: sampleCount
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: presentation,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(channelCount) * 4
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(sampleCount),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        return DecodedAudio(
            sampleBuffer: sampleBuffer,
            presentation: presentation,
            generation: generation,
            mediaDuration: Double(sampleCount) / Double(sampleRate),
            byteCount: bytes
        )
    }
}
