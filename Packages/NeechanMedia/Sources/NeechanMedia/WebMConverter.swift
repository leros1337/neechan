import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale

/// Turns a WebM into an MP4 the rest of the system can play.
///
/// Photos refuses a WebM outright (`PHPhotosErrorDomain 3302`), and it is not a
/// container problem that a remux would fix: iOS has no Matroska demuxer, and
/// AVFoundation cannot decode VP8 or VP9 in any wrapper. So this is a real
/// transcode — VP8/VP9 and Vorbis/Opus in, H.264 and AAC out.
///
/// The H.264 encoder is `h264_videotoolbox`, which is the hardware encoder the
/// system uses itself, so this costs far less than the name "transcode"
/// suggests; the software VP9 decode is the slow half.
///
/// There is no `ffmpeg -i` to call here: this package ships the libraries, not
/// the command line tool, so the read-decode-encode-write loop is written out.
public struct WebMConverter: Sendable {
    public enum ConversionError: Error, CustomStringConvertible, Equatable {
        case cannotOpen(String)
        case noVideo
        case noEncoder
        case failed(String, code: Int32)

        public var description: String {
            switch self {
            case .cannotOpen(let name): "\(name) could not be opened."
            case .noVideo: "The file holds no video."
            case .noEncoder: "This device has no H.264 encoder."
            case .failed(let step, let code): "\(step) failed (\(code))."
            }
        }
    }

    public init() {}

    /// The size to encode at, keeping the shape and staying even.
    ///
    /// H.264 wants even dimensions, and NV12's chroma plane is half size in
    /// both directions, so an odd number here is a broken last row.
    static func fitted(width: Int32, height: Int32, longSide: Int32) -> (Int32, Int32) {
        guard width > 0, height > 0 else { return (longSide, longSide) }
        let scale = min(1, Double(longSide) / Double(max(width, height)))
        let scaled = (Int32(Double(width) * scale), Int32(Double(height) * scale))
        return (max(2, scaled.0 - scaled.0 % 2), max(2, scaled.1 - scaled.1 % 2))
    }

    /// Roughly what a phone-sized clip needs, rather than whatever the source
    /// happened to use: a VP9 file re-encoded at its own bitrate looks worse.
    static func bitRate(width: Int32, height: Int32) -> Int64 {
        let pixels = Int64(width) * Int64(height)
        return min(8_000_000, max(800_000, pixels * 4))
    }

    /// AAC does not encode every rate; the odd ones are moved to the nearest
    /// that it does.
    static func supportedSampleRate(_ rate: Int32) -> Int32 {
        let supported: [Int32] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 96000]
        guard rate > 0 else { return 48000 }
        if supported.contains(rate) { return rate }
        return supported.min { abs($0 - rate) < abs($1 - rate) } ?? 48000
    }

    /// Converts `source` into an MP4 written to `destination`.
    ///
    /// Runs off the caller's actor: the loop is blocking C and would otherwise
    /// hold whatever executor asked for it for the length of the clip.
    ///
    /// - Parameter onProgress: 0...1, called as the file is worked through.
    public func convert(
        fileAt source: URL,
        to destination: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let sourcePath = source.path
        let destinationPath = destination.path
        try await Task.detached(priority: .userInitiated) {
            try Transcode(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                onProgress: onProgress
            ).run()
        }.value
    }
}

/// One conversion, with every C resource it owns.
///
/// A class rather than a function so `deinit` frees what was allocated however
/// the run ends: the loop has a dozen early exits and each one would otherwise
/// have to remember the same list.
private final class Transcode {
    private let sourcePath: String
    private let destinationPath: String
    private let onProgress: (@Sendable (Double) -> Void)?

    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var output: UnsafeMutablePointer<AVFormatContext>?
    private var videoDecoder: UnsafeMutablePointer<AVCodecContext>?
    private var videoEncoder: UnsafeMutablePointer<AVCodecContext>?
    private var audioDecoder: UnsafeMutablePointer<AVCodecContext>?
    private var audioEncoder: UnsafeMutablePointer<AVCodecContext>?
    private var scaler: OpaquePointer?
    private var resampler: OpaquePointer?
    private var fifo: OpaquePointer?

    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1
    private var outputVideoIndex: Int32 = 0
    private var outputAudioIndex: Int32 = -1
    /// Running count of samples handed to the audio encoder, which is where its
    /// timestamps come from.
    private var audioSamplesWritten: Int64 = 0
    private var didWriteHeader = false

    init(
        sourcePath: String,
        destinationPath: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.onProgress = onProgress
    }

    deinit {
        avformat_close_input(&input)
        if let output {
            if output.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
                avio_closep(&output.pointee.pb)
            }
            avformat_free_context(output)
        }
        avcodec_free_context(&videoDecoder)
        avcodec_free_context(&videoEncoder)
        avcodec_free_context(&audioDecoder)
        avcodec_free_context(&audioEncoder)
        sws_freeContext(scaler)
        if resampler != nil { swr_free(&resampler) }
        if fifo != nil { av_audio_fifo_free(fifo) }
    }

    func run() throws {
        try openInput()
        try openOutput()
        try writeHeader()
        try transcode()
        try flush()
    }

    // MARK: Input

    private func openInput() throws {
        var context = avformat_alloc_context()
        guard avformat_open_input(&context, sourcePath, nil, nil) == 0, let context else {
            throw WebMConverter.ConversionError.cannotOpen("The video")
        }
        input = context
        guard avformat_find_stream_info(context, nil) >= 0 else {
            throw WebMConverter.ConversionError.cannotOpen("The video's streams")
        }

        videoStreamIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoStreamIndex >= 0 else { throw WebMConverter.ConversionError.noVideo }
        videoDecoder = try makeDecoder(for: videoStreamIndex)

        // Audio is optional: plenty of WebM clips on the board are silent.
        audioStreamIndex = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if audioStreamIndex >= 0 {
            audioDecoder = try? makeDecoder(for: audioStreamIndex)
            if audioDecoder == nil { audioStreamIndex = -1 }
        }
    }

    private func makeDecoder(for index: Int32) throws -> UnsafeMutablePointer<AVCodecContext> {
        guard
            let stream = input?.pointee.streams[Int(index)],
            let codec = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id),
            let context = avcodec_alloc_context3(codec)
        else { throw WebMConverter.ConversionError.cannotOpen("The video's codec") }

        guard
            avcodec_parameters_to_context(context, stream.pointee.codecpar) >= 0,
            avcodec_open2(context, codec, nil) >= 0
        else {
            var context: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&context)
            throw WebMConverter.ConversionError.cannotOpen("The video's codec")
        }
        context.pointee.pkt_timebase = stream.pointee.time_base
        return context
    }

    // MARK: Output

    private func openOutput() throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&context, nil, "mp4", destinationPath) >= 0,
              let context
        else { throw WebMConverter.ConversionError.cannotOpen("The converted file") }
        output = context

        try addVideoStream()
        if audioStreamIndex >= 0 { try addAudioStream() }

        if context.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            let result = avio_open(&context.pointee.pb, destinationPath, AVIO_FLAG_WRITE)
            guard result >= 0 else {
                throw WebMConverter.ConversionError.failed("Opening the converted file", code: result)
            }
        }
    }

    private func addVideoStream() throws {
        guard let decoder = videoDecoder, let output else { throw WebMConverter.ConversionError.noVideo }
        guard
            let codec = avcodec_find_encoder_by_name("h264_videotoolbox")
                ?? avcodec_find_encoder(AV_CODEC_ID_H264),
            let encoder = avcodec_alloc_context3(codec),
            let stream = avformat_new_stream(output, nil)
        else { throw WebMConverter.ConversionError.noEncoder }
        videoEncoder = encoder
        outputVideoIndex = stream.pointee.index

        // Capped rather than copied: a clip larger than this gains nothing on a
        // phone and costs encoding time for every extra pixel.
        let (width, height) = WebMConverter.fitted(
            width: decoder.pointee.width, height: decoder.pointee.height, longSide: 1920
        )
        encoder.pointee.width = width
        encoder.pointee.height = height
        encoder.pointee.pix_fmt = AV_PIX_FMT_NV12
        encoder.pointee.time_base = inputStream(videoStreamIndex).pointee.time_base
        encoder.pointee.framerate = av_guess_frame_rate(input, inputStream(videoStreamIndex), nil)
        encoder.pointee.bit_rate = WebMConverter.bitRate(width: width, height: height)
        // A keyframe every couple of seconds, so scrubbing the result works.
        encoder.pointee.gop_size = 60
        if output.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0 {
            encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        let result = avcodec_open2(encoder, codec, nil)
        guard result >= 0 else {
            throw WebMConverter.ConversionError.failed("Starting the H.264 encoder", code: result)
        }
        guard avcodec_parameters_from_context(stream.pointee.codecpar, encoder) >= 0 else {
            throw WebMConverter.ConversionError.noEncoder
        }
        stream.pointee.time_base = encoder.pointee.time_base

        scaler = sws_getContext(
            decoder.pointee.width, decoder.pointee.height, decoder.pointee.pix_fmt,
            width, height, AV_PIX_FMT_NV12,
            SWS_BILINEAR, nil, nil, nil
        )
        guard scaler != nil else {
            throw WebMConverter.ConversionError.failed("Preparing the picture conversion", code: 0)
        }
    }

    private func addAudioStream() throws {
        guard let decoder = audioDecoder, let output else { return }
        guard
            let codec = avcodec_find_encoder(AV_CODEC_ID_AAC),
            let encoder = avcodec_alloc_context3(codec),
            let stream = avformat_new_stream(output, nil)
        else {
            // Silent video is better than no video: drop the audio and carry on.
            audioStreamIndex = -1
            return
        }
        audioEncoder = encoder
        outputAudioIndex = stream.pointee.index

        let rate = WebMConverter.supportedSampleRate(decoder.pointee.sample_rate)
        encoder.pointee.sample_rate = rate
        encoder.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        encoder.pointee.bit_rate = 128_000
        encoder.pointee.time_base = AVRational(num: 1, den: rate)
        av_channel_layout_default(&encoder.pointee.ch_layout, min(2, decoder.pointee.ch_layout.nb_channels))
        if output.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0 {
            encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        guard avcodec_open2(encoder, codec, nil) >= 0,
              avcodec_parameters_from_context(stream.pointee.codecpar, encoder) >= 0
        else {
            audioStreamIndex = -1
            return
        }
        stream.pointee.time_base = encoder.pointee.time_base

        var resampler: OpaquePointer?
        let result = swr_alloc_set_opts2(
            &resampler,
            &encoder.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, rate,
            &decoder.pointee.ch_layout, decoder.pointee.sample_fmt, decoder.pointee.sample_rate,
            0, nil
        )
        guard result >= 0, let resampler, swr_init(resampler) >= 0 else {
            audioStreamIndex = -1
            return
        }
        self.resampler = resampler
        fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, encoder.pointee.ch_layout.nb_channels, 1)
    }

    private func writeHeader() throws {
        guard let output else { return }
        var options: OpaquePointer?
        // Puts the index at the front, so the file plays while it is still
        // being copied out of the app.
        av_dict_set(&options, "movflags", "+faststart", 0)
        defer { av_dict_free(&options) }
        let result = avformat_write_header(output, &options)
        guard result >= 0 else {
            throw WebMConverter.ConversionError.failed("Writing the file's header", code: result)
        }
        didWriteHeader = true
    }

    // MARK: The loop

    private func transcode() throws {
        guard let input else { return }
        let packet = av_packet_alloc()
        let frame = av_frame_alloc()
        defer {
            var packet = packet
            var frame = frame
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        let duration = Double(input.pointee.duration) / Double(AV_TIME_BASE)

        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            try Task.checkCancellation()

            if packet?.pointee.stream_index == videoStreamIndex {
                try decode(packet, with: videoDecoder, into: frame, isVideo: true)
                report(progress: packet, duration: duration)
            } else if audioStreamIndex >= 0, packet?.pointee.stream_index == audioStreamIndex {
                try decode(packet, with: audioDecoder, into: frame, isVideo: false)
            }
        }
    }

    /// Feeds one packet to a decoder and passes every frame that comes out on.
    private func decode(
        _ packet: UnsafeMutablePointer<AVPacket>?,
        with decoder: UnsafeMutablePointer<AVCodecContext>?,
        into frame: UnsafeMutablePointer<AVFrame>?,
        isVideo: Bool
    ) throws {
        guard let decoder else { return }
        guard avcodec_send_packet(decoder, packet) >= 0 else { return }
        while avcodec_receive_frame(decoder, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if isVideo {
                try encodeVideo(frame)
            } else {
                try encodeAudio(frame)
            }
        }
    }

    private func encodeVideo(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
        guard let encoder = videoEncoder, let scaler, let frame else { return }
        guard let converted = av_frame_alloc() else { return }
        defer {
            var converted: UnsafeMutablePointer<AVFrame>? = converted
            av_frame_free(&converted)
        }
        converted.pointee.format = Int32(AV_PIX_FMT_NV12.rawValue)
        converted.pointee.width = encoder.pointee.width
        converted.pointee.height = encoder.pointee.height
        guard av_frame_get_buffer(converted, 0) >= 0 else { return }
        guard sws_scale_frame(scaler, converted, frame) >= 0 else { return }

        // The decoder's own timestamp, which is already in the encoder's time
        // base because the encoder took the input stream's.
        converted.pointee.pts = frame.pointee.best_effort_timestamp
        try encode(converted, with: encoder, streamIndex: outputVideoIndex)
    }

    private func encodeAudio(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
        guard
            let encoder = audioEncoder, let resampler, let fifo, let frame,
            let resampled = av_frame_alloc()
        else { return }
        defer {
            var resampled: UnsafeMutablePointer<AVFrame>? = resampled
            av_frame_free(&resampled)
        }

        resampled.pointee.format = Int32(AV_SAMPLE_FMT_FLTP.rawValue)
        resampled.pointee.sample_rate = encoder.pointee.sample_rate
        av_channel_layout_copy(&resampled.pointee.ch_layout, &encoder.pointee.ch_layout)
        guard swr_convert_frame(resampler, resampled, frame) >= 0 else { return }
        guard resampled.pointee.nb_samples > 0 else { return }

        let written = resampled.pointee.extended_data.withMemoryRebound(
            to: UnsafeMutableRawPointer?.self, capacity: Int(resampled.pointee.ch_layout.nb_channels)
        ) { data in
            av_audio_fifo_write(fifo, data, resampled.pointee.nb_samples)
        }
        guard written > 0 else { return }

        // The encoder wants frames of one size; the decoder hands over whatever
        // the file happened to store, so the queue is what squares them.
        try drainFIFO(keepingPartialFrame: true)
    }

    /// Hands the queued audio to the encoder in frames of its own size.
    private func drainFIFO(keepingPartialFrame: Bool) throws {
        guard let encoder = audioEncoder, let fifo else { return }
        let frameSize = encoder.pointee.frame_size > 0 ? encoder.pointee.frame_size : 1024

        while av_audio_fifo_size(fifo) >= (keepingPartialFrame ? frameSize : 1) {
            let count = min(frameSize, av_audio_fifo_size(fifo))
            guard let frame = av_frame_alloc() else { return }
            defer {
                var frame: UnsafeMutablePointer<AVFrame>? = frame
                av_frame_free(&frame)
            }
            frame.pointee.nb_samples = count
            frame.pointee.format = Int32(AV_SAMPLE_FMT_FLTP.rawValue)
            frame.pointee.sample_rate = encoder.pointee.sample_rate
            av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
            guard av_frame_get_buffer(frame, 0) >= 0 else { return }

            let read = frame.pointee.extended_data.withMemoryRebound(
                to: UnsafeMutableRawPointer?.self, capacity: Int(frame.pointee.ch_layout.nb_channels)
            ) { data in
                av_audio_fifo_read(fifo, data, count)
            }
            guard read > 0 else { return }

            frame.pointee.pts = audioSamplesWritten
            audioSamplesWritten += Int64(read)
            try encode(frame, with: encoder, streamIndex: outputAudioIndex)
        }
    }

    /// Sends one frame to an encoder and writes whatever it gives back.
    private func encode(
        _ frame: UnsafeMutablePointer<AVFrame>?,
        with encoder: UnsafeMutablePointer<AVCodecContext>,
        streamIndex: Int32
    ) throws {
        guard let output, let packet = av_packet_alloc() else { return }
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
        }

        // A flush (a nil frame) may answer "already ended", which is not a
        // failure; `AVERROR_EOF` is a macro and does not reach Swift.
        let sent = avcodec_send_frame(encoder, frame)
        guard sent >= 0 || frame == nil else {
            throw WebMConverter.ConversionError.failed("Encoding", code: sent)
        }
        while avcodec_receive_packet(encoder, packet) >= 0 {
            packet.pointee.stream_index = streamIndex
            av_packet_rescale_ts(
                packet,
                encoder.pointee.time_base,
                output.pointee.streams[Int(streamIndex)]!.pointee.time_base
            )
            let result = av_interleaved_write_frame(output, packet)
            guard result >= 0 else {
                throw WebMConverter.ConversionError.failed("Writing the converted video", code: result)
            }
        }
    }

    private func flush() throws {
        // Whatever the decoders are still holding, then whatever the encoders
        // are: a file cut off at the last full frame loses its tail.
        let frame = av_frame_alloc()
        defer {
            var frame = frame
            av_frame_free(&frame)
        }
        try decode(nil, with: videoDecoder, into: frame, isVideo: true)
        if audioStreamIndex >= 0 {
            try decode(nil, with: audioDecoder, into: frame, isVideo: false)
            try drainFIFO(keepingPartialFrame: false)
        }
        if let videoEncoder { try encode(nil, with: videoEncoder, streamIndex: outputVideoIndex) }
        if let audioEncoder, outputAudioIndex >= 0 {
            try encode(nil, with: audioEncoder, streamIndex: outputAudioIndex)
        }

        if didWriteHeader, let output {
            let result = av_write_trailer(output)
            guard result >= 0 else {
                throw WebMConverter.ConversionError.failed("Finishing the converted file", code: result)
            }
        }
        onProgress?(1)
    }

    // MARK: Small things

    private func inputStream(_ index: Int32) -> UnsafeMutablePointer<AVStream> {
        input!.pointee.streams[Int(index)]!
    }

    private func report(progress packet: UnsafeMutablePointer<AVPacket>?, duration: Double) {
        guard let onProgress, duration > 0, let packet, packet.pointee.pts != Int64.min else { return }
        let timeBase = inputStream(videoStreamIndex).pointee.time_base
        let seconds = Double(packet.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
        onProgress(min(1, max(0, seconds / duration)))
    }

}
