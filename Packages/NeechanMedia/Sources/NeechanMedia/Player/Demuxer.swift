import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Synchronization

/// Where a file's bytes come from.
enum MediaSource: @unchecked Sendable {
    /// Already on disk, in the media cache. FFmpeg reads it itself.
    case file(URL)
    /// Still arriving. Read through the app's own networking.
    case remote(MediaRangeReader)
}

/// One packet, and the memory FFmpeg allocated for it.
///
/// A class rather than a struct so that the packet is freed exactly once, when
/// the last reference goes, however far down the queue it travelled.
final class OwnedPacket: QueuedMedia, @unchecked Sendable {
    let packet: UnsafeMutablePointer<AVPacket>
    let streamIndex: Int32
    let mediaDuration: Double
    let byteCount: Int

    init(packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) {
        self.packet = packet
        streamIndex = packet.pointee.stream_index
        let duration = packet.pointee.duration
        mediaDuration = duration > 0 && timeBase.den > 0
            ? Double(duration) * Double(timeBase.num) / Double(timeBase.den)
            : 0
        byteCount = Int(packet.pointee.size)
    }

    /// Whether the container says this packet decodes on its own.
    var isKeyframe: Bool { packet.pointee.flags & Int32(AV_PKT_FLAG_KEY) != 0 }

    deinit {
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&owned)
    }
}

/// Reads a file and hands out its packets.
///
/// Owns the format context, and is the only thing that touches it. Everything
/// here runs on the demuxing thread, except `cancel`, which any thread may
/// call to end a read that is waiting on the network.
final class Demuxer: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case cannotOpen(Int32)
        case noStreamInfo(Int32)
        case noPlayableStream

        var description: String {
            switch self {
            case .cannotOpen(let code): "The file could not be opened (\(FFmpegStatus.message(code)))."
            case .noStreamInfo(let code): "The file's contents could not be read (\(FFmpegStatus.message(code)))."
            case .noPlayableStream: "The file holds nothing that can be played."
            }
        }
    }

    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var io: RangeReaderIO?
    /// Read by the interrupt callback from inside a blocking read, so that
    /// tearing a player down does not wait for the network to answer.
    private let isCancelled = Mutex(false)
    /// The same lever, pulled for a seek rather than for teardown.
    ///
    /// A read waiting on the network holds the reading thread, and a seek that
    /// has to wait for it lands seconds after the reader let go of the
    /// scrubber. This cuts the read short so the seek can be answered at once.
    private let isInterrupted = Mutex(false)

    private(set) var videoStream: UnsafeMutablePointer<AVStream>?

    /// Packets read while making sure a seek landed on a keyframe, handed out
    /// before anything new is read. Like everything else here that moves the
    /// file, only the reading thread touches it.
    private var readAhead: [OwnedPacket] = []
    /// Every keyframe of the picture read so far, in its stream's time base
    /// and in order. What a seek falls back on when the file's index is wrong.
    private var keyframes: [Int64] = []
    private(set) var audioStream: UnsafeMutablePointer<AVStream>?

    /// What FFmpeg found the file to be, from its bytes rather than its name:
    /// "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2", "avi". A board checks the
    /// name, so the two can disagree.
    private(set) var containerName = "unknown"

    init(source: MediaSource) throws {
        guard var context = avformat_alloc_context() else {
            throw Failure.cannotOpen(0)
        }

        context.pointee.interrupt_callback = AVIOInterruptCB(
            callback: ffmpegShouldInterrupt,
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )

        var path: String?
        switch source {
        case .file(let url):
            path = url.path
        case .remote(let reader):
            let io = RangeReaderIO(reader: reader)
            self.io = io
            context.pointee.pb = io.context
            context.pointee.flags |= FFmpegStatus.customIO
        }

        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        let openResult = avformat_open_input(&opened, path, nil, nil)
        guard openResult == 0, let opened else {
            // avformat_open_input frees the context itself when it fails, so
            // only the byte source is left to give back.
            self.context = nil
            self.io?.close()
            self.io = nil
            throw Failure.cannotOpen(openResult)
        }
        context = opened
        self.context = opened

        let infoResult = avformat_find_stream_info(context, nil)
        guard infoResult >= 0 else {
            throw Failure.noStreamInfo(infoResult)
        }

        let video = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        let audio = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if video >= 0 { videoStream = context.pointee.streams[Int(video)] }
        if audio >= 0 { audioStream = context.pointee.streams[Int(audio)] }
        guard videoStream != nil || audioStream != nil else {
            throw Failure.noPlayableStream
        }

        // Set once the demuxer exists to be asked. Reads stop the moment this
        // one is given up on or sent somewhere else, rather than working
        // through their retries first.
        io?.shouldStopReading = { [weak self] in self?.shouldInterrupt ?? true }

        containerName = context.pointee.iformat.map { String(cString: $0.pointee.name) } ?? "unknown"
        MediaLog.demuxer.debug(
            """
            opened \(self.containerName, privacy: .public): \
            \(self.duration, format: .fixed(precision: 1), privacy: .public)s, \
            \(Int(self.naturalSize.width), privacy: .public)x\(Int(self.naturalSize.height), privacy: .public), \
            rotated \(self.rotationDegrees, format: .fixed(precision: 0), privacy: .public)°, \
            \(context.pointee.bit_rate / 1000, privacy: .public) kbps overall
            """
        )
    }

    deinit {
        close()
    }

    func close() {
        if context != nil {
            var owned: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&owned)
            context = nil
        }
        // Closing the format context does not give a custom source back: that
        // is the app's, and has to be freed by the app.
        io?.close()
        io = nil
    }

    /// Ends any read that is waiting, and refuses the ones after it.
    func cancel() {
        isCancelled.withLock { $0 = true }
        io?.abandonInFlightRequest()
    }

    /// Cuts a waiting read short so a seek can be answered now.
    ///
    /// Two levers, because a read can be waiting in either of two places.
    /// FFmpeg checks the interrupt flag while it waits on its own; a read
    /// waiting inside the app's networking is beyond its reach, and only
    /// giving up the request frees it.
    func interruptForSeek() {
        isInterrupted.withLock { $0 = true }
        io?.abandonInFlightRequest()
    }

    /// Lets reading start again, once the seek has been made.
    ///
    /// A read cut short leaves its failure on FFmpeg's byte source, along
    /// with a mark saying the end was reached, and FFmpeg forgets neither by
    /// itself. The next time the demuxer came to an end of any kind, the end
    /// was reported as that failure, and a clip that had just seeked perfectly
    /// well stopped with an input/output error. The read was cut short on
    /// purpose; nothing is wrong with the file.
    func resumeAfterSeek() {
        isInterrupted.withLock { $0 = false }
        if let source = context?.pointee.pb {
            source.pointee.error = 0
            source.pointee.eof_reached = 0
        }
    }

    var isCancelledNow: Bool { isCancelled.withLock { $0 } }

    fileprivate var shouldInterrupt: Bool {
        isCancelled.withLock { $0 } || isInterrupted.withLock { $0 }
    }

    /// How long the file runs, or zero when it does not say.
    ///
    /// Taken from the container rather than a stream: a WebM often gives its
    /// streams no duration at all while the file itself carries one.
    var duration: TimeInterval {
        guard let context, context.pointee.duration > 0 else { return 0 }
        return TimeInterval(context.pointee.duration) / TimeInterval(AV_TIME_BASE)
    }

    /// The picture's size, before any rotation is applied.
    var naturalSize: CGSize {
        guard let parameters = videoStream?.pointee.codecpar else { return .zero }
        return CGSize(width: Int(parameters.pointee.width), height: Int(parameters.pointee.height))
    }

    /// How far the picture has to be turned to be the right way up.
    ///
    /// Phones write this rather than rotating the pixels, so a clip recorded
    /// upright arrives on its side with a note saying so.
    var rotationDegrees: Double {
        guard let parameters = videoStream?.pointee.codecpar else { return 0 }
        guard let entry = av_packet_side_data_get(
            parameters.pointee.coded_side_data,
            parameters.pointee.nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX
        ) else { return 0 }
        guard let data = entry.pointee.data, entry.pointee.size >= MemoryLayout<Int32>.size * 9 else {
            return 0
        }
        let matrix = UnsafeRawPointer(data).assumingMemoryBound(to: Int32.self)
        let rotation = -av_display_rotation_get(matrix)
        guard rotation.isFinite else { return 0 }
        return rotation.truncatingRemainder(dividingBy: 360)
    }

    /// What a read produced.
    enum ReadOutcome {
        case packet(OwnedPacket)
        /// The file is genuinely over.
        case endOfFile
        /// The bytes could not be reached. Not the same thing at all: a clip
        /// that ends here has not finished, it has been cut off.
        case failed(Int32)
        /// The player is being torn down.
        case cancelled
        /// A seek cut the read short. Nothing is wrong.
        case interrupted
    }

    /// The next packet.
    func read() -> ReadOutcome {
        if isCancelledNow { return .cancelled }
        if shouldInterrupt { return .interrupted }
        if !readAhead.isEmpty { return .packet(readAhead.removeFirst()) }
        return readFromFile()
    }

    private func readFromFile() -> ReadOutcome {
        if isCancelledNow { return .cancelled }
        if shouldInterrupt { return .interrupted }
        guard let context, let packet = av_packet_alloc() else { return .failed(0) }

        while true {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            let result = av_read_frame(context, packet)
            guard result >= 0 else {
                av_packet_free(&owned)
                if isCancelledNow { return .cancelled }
                if shouldInterrupt { return .interrupted }
                if result == FFmpegStatus.endOfFile {
                    MediaLog.demuxer.debug("reached the end of the file")
                    return .endOfFile
                }
                MediaLog.demuxer.error(
                    "read failed: \(FFmpegStatus.message(result), privacy: .public)"
                )
                return .failed(result)
            }

            // A packet the container could not read whole: the bytes stopped
            // partway through it, as they do when a seek abandons the download
            // a packet was in the middle of. FFmpeg hands the stub over rather
            // than failing the read, and a decoder given it reports invalid
            // data, sometimes several packets later once its threads catch up.
            // It belongs to nothing; it is thrown away here.
            if packet.pointee.flags & Int32(AV_PKT_FLAG_CORRUPT) != 0 {
                MediaLog.demuxer.debug(
                    "dropped a packet cut short at \(packet.pointee.size, privacy: .public) bytes"
                )
                av_packet_unref(packet)
                if isCancelledNow { av_packet_free(&owned); return .cancelled }
                if shouldInterrupt { av_packet_free(&owned); return .interrupted }
                continue
            }

            let index = packet.pointee.stream_index
            guard index == videoStream?.pointee.index || index == audioStream?.pointee.index else {
                // A stream nothing is listening to: subtitles, chapters, the
                // cover art a Matroska file may carry.
                av_packet_unref(packet)
                continue
            }
            let read = OwnedPacket(packet: packet, timeBase: timeBase(ofStream: index))
            if index == videoStream?.pointee.index, read.isKeyframe { noteKeyframe(read) }
            return .packet(read)
        }
    }

    private func noteKeyframe(_ packet: OwnedPacket) {
        let time = packet.packet.pointee.pts != FFmpegStatus.noTimestamp
            ? packet.packet.pointee.pts
            : packet.packet.pointee.dts
        guard time != FFmpegStatus.noTimestamp else { return }
        // Nearly always the latest yet; after a seek back, often one already
        // known.
        if let last = keyframes.last, time <= last {
            let at = keyframes.firstIndex { $0 >= time } ?? keyframes.endIndex
            if at < keyframes.endIndex, keyframes[at] == time { return }
            keyframes.insert(time, at: at)
        } else {
            keyframes.append(time)
        }
    }

    /// The next packet, or nil for anything else. For the tests, which do not
    /// care why a file stopped.
    func readPacket() -> OwnedPacket? {
        // Cancellation is checked in `read` as well as in the interrupt
        // callback. FFmpeg consults that callback while it waits on input,
        // which is what unblocks a read stuck on the network, but a file
        // already in the page cache never waits and so is never asked.
        guard case .packet(let packet) = read() else { return nil }
        return packet
    }

    /// Moves to `time`, landing on the keyframe at or before it.
    ///
    /// FFmpeg goes wherever the file's index says, and an index can be wrong.
    /// Old Matroska muxers listed every frame in it as a keyframe, and 2ch
    /// still serves their files: a seek landed on a picture that cannot be
    /// decoded without the ones before it, and the decoder refused everything
    /// up to the next real keyframe, which in one clip was eleven seconds on.
    /// The clip failed, or showed that keyframe over the sound from where the
    /// reader had asked.
    ///
    /// So where it lands is checked. A seek that misses goes to the nearest
    /// keyframe already read before the target, which while playing is
    /// usually close because the reader runs well ahead, and failing that to
    /// the start. Either way the pictures up to the target are decoded and
    /// thrown away, as after any seek.
    ///
    /// Running off the end of the file without a picture is a miss as well.
    /// An index written at the front of a file describes the whole of it, and
    /// a file cut off partway keeps that index: 2ch serves one that declares
    /// fifty seconds and holds thirteen, whose index sends any seek past the
    /// thirteenth to bytes that are not there.
    @discardableResult
    func seek(to time: TimeInterval) -> Bool {
        lastSeekMissed = false
        guard let context else { return false }
        readAhead.removeAll()
        let target = Int64(max(0, time) * TimeInterval(AV_TIME_BASE))
        guard av_seek_frame(context, -1, target, FFmpegStatus.seekBackward) >= 0 else { return false }
        guard let video = videoStream else { return true }

        let miss: String
        switch landing() {
        case .keyframe, .unknown:
            return true
        case .notKeyframe:
            miss = "a picture that is not a keyframe"
        case .noPicture:
            miss = "the end of the file with no picture on the way"
        }

        lastSeekMissed = true
        let index = video.pointee.index
        let inStream = av_rescale_q(target, AVRational(num: 1, den: AV_TIME_BASE), video.pointee.time_base)
        if let known = keyframes.last(where: { $0 <= inStream }) {
            readAhead.removeAll()
            if av_seek_frame(context, index, known, FFmpegStatus.seekBackward) >= 0, landing() == .keyframe {
                MediaLog.demuxer.warning(
                    """
                    the file's index sent a seek to \(miss, privacy: .public); \
                    went back to the keyframe at \(TimeMath.seconds(TimeMath.time(known, numerator: video.pointee.time_base.num, denominator: video.pointee.time_base.den)), format: .fixed(precision: 3), privacy: .public)s
                    """
                )
                return true
            }
        }

        MediaLog.demuxer.warning(
            "the file's index sent a seek to \(miss, privacy: .public); went back to the start"
        )
        readAhead.removeAll()
        guard av_seek_frame(context, -1, 0, FFmpegStatus.seekBackward) >= 0 else { return false }
        _ = landing()
        return true
    }

    /// Whether the last seek missed, and went back to a keyframe already read
    /// or to the start instead. The player decodes forward from there as from
    /// any keyframe; the scrubber's previews, which show the keyframe itself,
    /// would show a picture of somewhere else.
    private(set) var lastSeekMissed = false

    /// Where a seek put the reading, judged by the first picture after it.
    private enum Landing: Equatable {
        case keyframe
        case notKeyframe
        /// The file ran out before a picture turned up.
        case noPicture
        /// Nothing more to learn: a read that failed, or a seek overtaken by
        /// another. `read` reports those itself once what was kept has gone.
        case unknown
    }

    /// Reads up to the first picture, keeping everything read for `read` to
    /// hand out, and says what that picture was.
    private func landing() -> Landing {
        let index = videoStream?.pointee.index
        // A picture always turns up within a few packets of sound; a file
        // where it does not is not worth reading through.
        while readAhead.count < 512 {
            switch readFromFile() {
            case .packet(let packet):
                readAhead.append(packet)
                if packet.streamIndex == index { return packet.isKeyframe ? .keyframe : .notKeyframe }
            case .endOfFile:
                return .noPicture
            case .failed, .cancelled, .interrupted:
                return .unknown
            }
        }
        return .unknown
    }

    /// The time base of a stream, by index.
    func timeBase(ofStream index: Int32) -> AVRational {
        guard let context, index >= 0, index < Int32(context.pointee.nb_streams) else {
            return AVRational(num: 1, den: 1_000)
        }
        return context.pointee.streams[Int(index)]!.pointee.time_base
    }
}

private let ffmpegShouldInterrupt: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
    guard let opaque else { return 0 }
    let demuxer = Unmanaged<Demuxer>.fromOpaque(opaque).takeUnretainedValue()
    return demuxer.shouldInterrupt ? 1 : 0
}
