import CoreGraphics
import CoreMedia
import Foundation
import Synchronization

/// One file, from bytes to something ready to show.
///
/// Three threads: one reading the file, one decoding pictures, one decoding
/// sound. They are threads rather than tasks because every call into FFmpeg
/// blocks, and a blocking call on a cooperative pool holds a thread that the
/// rest of the app is entitled to.
///
/// A pipeline belongs to one file. Playing another means building another,
/// which is also how a feed that swaps the clip under a single player works.
final class Pipeline: @unchecked Sendable {
    private let demuxer: Demuxer
    private let videoStreamIndex: Int32?
    private let audioStreamIndex: Int32?

    /// Packets waiting to be decoded, and pictures waiting to be shown.
    ///
    /// Two seconds of each: enough that a hiccup in the network does not show,
    /// little enough that a clip starts quickly and a gallery paging through
    /// them does not hold several files' worth of memory at once.
    private let videoPackets = BoundedQueue<OwnedPacket>(durationLimit: 20, byteLimit: 64 << 20)
    private let audioPackets = BoundedQueue<OwnedPacket>(durationLimit: 20, byteLimit: 16 << 20)
    let videoFrames = BoundedQueue<DecodedFrame>(durationLimit: 0.5, byteLimit: 32 << 20)
    let audioRuns = BoundedQueue<DecodedAudio>(durationLimit: 1)

    private let capabilities: VideoDecoderCapabilities
    private let isCancelled = Mutex(false)
    /// Where a seek is heading, so pictures from before it can be dropped and
    /// playback resumes where the reader asked rather than at the keyframe
    /// before it. Also decides which picture is announced as the first: the
    /// two are one value on purpose, see `FirstFrameGate`.
    ///
    /// The sound keeps a target of its own, because the two decoders reach it
    /// at different moments and each has to stop discarding on its own.
    /// Sharing one let whichever arrived first clear it for both.
    private let gate = Mutex(FirstFrameGate())
    private let audioSeekTarget = Mutex<TimeInterval?>(nil)
    private let pendingSeek = Mutex<TimeInterval?>(nil)
    /// How many pictures were decoded and thrown away getting back to where
    /// the reader asked for, which is how far the keyframe was behind it.
    private let droppedSinceSeek = Mutex(0)

    /// Called when there is something to show: once after opening, and once
    /// after every seek, with the seek's target so a report can be matched to
    /// the seek it answers rather than taken for a later one.
    var onFirstFrame: (@Sendable (_ forSeek: TimeInterval?) -> Void)?
    /// Called if decoding fails outright.
    var onFailed: (@Sendable (String) -> Void)?

    var duration: TimeInterval { demuxer.duration }
    var naturalSize: CGSize { demuxer.naturalSize }
    var rotationDegrees: Double { demuxer.rotationDegrees }
    var hasVideo: Bool { videoStreamIndex != nil }
    var hasAudio: Bool { audioStreamIndex != nil }

    private(set) var isDecodingInHardware = false

    init(source: MediaSource, capabilities: VideoDecoderCapabilities = .current) throws {
        demuxer = try Demuxer(source: source)
        self.capabilities = capabilities
        videoStreamIndex = demuxer.videoStream?.pointee.index
        audioStreamIndex = demuxer.audioStream?.pointee.index
    }

    /// Starts reading and decoding.
    func start() {
        startThread(named: "io.neechan.media.demux", body: demuxLoop)
        if demuxer.videoStream != nil {
            startThread(named: "io.neechan.media.video", body: decodeVideoLoop)
        }
        if demuxer.audioStream != nil {
            startThread(named: "io.neechan.media.audio", body: decodeAudioLoop)
        }
    }

    /// Stops everything, without waiting for the network.
    func cancel() {
        isCancelled.withLock { $0 = true }
        demuxer.cancel()
        videoPackets.close()
        audioPackets.close()
        videoFrames.close()
        audioRuns.close()
    }

    /// Asks for playback to continue from `time`.
    ///
    /// Everything queued is thrown away at once so the picture does not
    /// continue from where it was, and the reading thread moves the file when
    /// it next comes round, which it does promptly because its own queues just
    /// emptied.
    func seek(to time: TimeInterval) {
        // One change, under one lock: from here on nothing is announced to
        // the player until a picture for this position has been queued.
        // Starting the clock before then runs it against an empty renderer,
        // and the frames arrive already in the past.
        gate.withLock { $0.beginSeek(to: time) }
        audioSeekTarget.withLock { $0 = time }
        pendingSeek.withLock { $0 = time }
        // Cut short whatever read is in flight so the seek is answered now
        // rather than whenever the network gets round to answering.
        demuxer.interruptForSeek()
        videoPackets.flush()
        audioPackets.flush()
        videoFrames.flush()
        audioRuns.flush()
    }

    private var isStopped: Bool { isCancelled.withLock { $0 } }

    private func startThread(named name: String, body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - Reading

    private func demuxLoop() {
        while !isStopped {
            if let target = pendingSeek.withLock({ value -> TimeInterval? in
                defer { value = nil }
                return value
            }) {
                demuxer.resumeAfterSeek()
                let moved = demuxer.seek(to: target)
                MediaLog.demuxer.debug(
                    """
                    moved to \(target, format: .fixed(precision: 3), privacy: .public)s:                     \(moved ? "yes" : "no", privacy: .public)
                    """
                )
                droppedSinceSeek.withLock { $0 = 0 }
            }

            switch demuxer.read() {
            case .packet(let packet):
                if packet.streamIndex == videoStreamIndex {
                    videoPackets.push(packet, generation: videoPackets.currentGeneration)
                } else if packet.streamIndex == audioStreamIndex {
                    audioPackets.push(packet, generation: audioPackets.currentGeneration)
                }

            case .endOfFile:
                // The decoders are told there is no more, so they drain what
                // they are holding rather than wait.
                MediaLog.demuxer.debug("finished reading, draining the decoders")
                let reached = videoPackets.currentGeneration
                videoPackets.finish()
                audioPackets.finish()
                // Parked, not finished. A reader who scrubs back into the clip
                // or plays it again needs this thread; one that has returned
                // can answer neither, and the picture sits on its last frame.
                guard videoPackets.waitForFlush(after: reached) else { return }
                MediaLog.demuxer.debug("sent back into the clip")
                continue

            case .failed(let code):
                // Not the end of the clip: the bytes stopped arriving. Saying
                // the file ended here would leave the reader looking at a
                // video that stopped halfway with nothing to say why.
                MediaLog.demuxer.error(
                    "stopped early: \(FFmpegStatus.message(code), privacy: .public)"
                )
                videoPackets.finish()
                audioPackets.finish()
                onFailed?(FFmpegStatus.message(code))
                return

            case .interrupted:
                // A seek pulled the lever. The loop comes round, makes the
                // seek and carries on; nothing has gone wrong.
                demuxer.resumeAfterSeek()
                continue

            case .cancelled:
                MediaLog.demuxer.debug("cancelled")
                videoPackets.finish()
                audioPackets.finish()
                return
            }
        }
    }

    // MARK: - Decoding

    private func decodeVideoLoop() {
        // As with the sound: whatever happens, say that no more pictures are
        // coming, so what is waiting for the end of the clip can stop waiting.
        defer { videoFrames.finish() }

        guard let stream = demuxer.videoStream else { return }
        let decoder: VideoDecoder
        do {
            decoder = try VideoDecoder(stream: stream, capabilities: capabilities)
        } catch {
            MediaLog.decoder.error("the picture will not decode: \(String(describing: error), privacy: .public)")
            onFailed?("\(error)")
            return
        }
        defer { decoder.close() }

        var lastGeneration = videoPackets.currentGeneration
        while !isStopped {
            let generation = videoPackets.currentGeneration
            if generation != lastGeneration {
                // A seek happened. Whatever the decoder is holding belongs to
                // the old position.
                decoder.flush()
                lastGeneration = generation
            }

            switch videoPackets.pop() {
            case .item(let packet):
                decodeVideo(packet, with: decoder, generation: generation)
            case .endOfStream:
                // Drain: a stream with B-frames holds its last pictures back
                // until it is told there is nothing more coming.
                try? decoder.decode(nil, generation: generation) { emit($0) }
                videoFrames.finish()
                // Then wait to be sent round again rather than ending here.
                guard videoPackets.waitForFlush(after: generation) else { return }
                decoder.flush()
                lastGeneration = videoPackets.currentGeneration
                continue
            case .closed:
                return
            }
        }
    }

    private func decodeVideo(_ packet: OwnedPacket, with decoder: VideoDecoder, generation: Int) {
        do {
            try decoder.decode(packet, generation: generation) { frame in
                isDecodingInHardware = decoder.isDecodingInHardware
                decodeFailures.succeeded()
                emit(frame)
            }
        } catch {
            // One packet that will not decode is not a clip that will not
            // decode: the decoder picks up again at the next keyframe. Seen
            // after a seek cut a download short, and reported by the decoder
            // seven seconds later alongside the first good picture of the new
            // position. Failing the clip on it turned a scrub into an error.
            MediaLog.decoder.error(
                "a packet would not decode: \(String(describing: error), privacy: .public)"
            )
            if decodeFailures.failed() {
                onFailed?("\(error)")
            }
        }
    }

    /// Failures in a row on the video thread; only that thread touches it.
    private nonisolated(unsafe) var decodeFailures = DecodeFailureTally()

    private func emit(_ frame: DecodedFrame) {
        // After a seek the file starts again at the keyframe before the time
        // asked for, so the pictures between the two are decoded and thrown
        // away. Without this a scrub lands wherever the last keyframe was.
        if let target = gate.withLock({ $0.seekTarget }) {
            let time = TimeMath.seconds(frame.presentation)
            if frame.presentation.isValid, !Self.isForSeek(time: time, target: target) {
                droppedSinceSeek.withLock { $0 += 1 }
                return
            }
            // The target is cleared only once a picture has actually been
            // taken. A picture left over from where the clip was before the
            // seek fails this push, and clearing on sight let it stand in for
            // the one being waited for: the clock then started at the new
            // position with nothing there to show, and the picture froze.
            guard videoFrames.push(frame, generation: frame.generation) else { return }
            // A later seek may have replaced this one while the push waited;
            // then this picture answers nothing and the gate says so.
            guard let answered = gate.withLock({ $0.claimSeekReport() }) else { return }
            MediaLog.decoder.debug(
                """
                first picture after the seek at \(time, format: .fixed(precision: 3), privacy: .public)s,                 \(self.droppedSinceSeek.withLock { $0 }, privacy: .public) dropped on the way
                """
            )
            onFirstFrame?(answered)
            return
        }

        guard videoFrames.push(frame, generation: frame.generation) else { return }
        // Claimed after the push, under the same lock a seek uses: a picture
        // of the old position whose push straddled a seek is refused here,
        // where it used to be taken for the seek's first picture.
        if gate.withLock({ $0.claimPlainReport() }) { onFirstFrame?(nil) }
    }

    /// Whether a decoded picture or run of sound belongs to the seek being
    /// waited on.
    ///
    /// At or after where the reader asked, and not so far after that it cannot
    /// be: a file is rewound to the keyframe before the target and decoded
    /// forward, so what is waited for arrives just after it. Anything much
    /// later is left over from wherever the clip was before.
    static func isForSeek(time: Double, target: Double) -> Bool {
        time + 0.001 >= target && time <= target + seekWindow
    }

    /// How far past the target a picture may be and still be the one the seek
    /// was waiting for. Generous, because a sparse file can put the first
    /// decodable picture some way beyond where the reader pointed.
    static let seekWindow: Double = 5

    /// Queues a run of sound, unless it belongs before a seek.
    ///
    /// Without this the sound after a seek starts from the keyframe the file
    /// was rewound to rather than from where the reader asked. Worse, it fills
    /// its queues with that sound while the picture is still decoding its way
    /// forward, and since one thread reads for both, a full audio queue stops
    /// the picture getting any packets at all. The clip then never reaches the
    /// place it was sent to.
    private func emit(_ run: DecodedAudio) {
        if let target = audioSeekTarget.withLock({ $0 }) {
            let time = TimeMath.seconds(run.presentation) + run.mediaDuration
            // Only sound from before where the reader asked is dropped.
            //
            // Deliberately not `isForSeek`, which is a picture's test: a
            // picture has to be recognised as *the* one the seek was waiting
            // for, so it is bounded above as well. Sound only has to stop
            // being the old position's. Bounding it above stranded the target
            // whenever the first run past it overshot the window — a sparse
            // file, or a seek close to the end — and every run for the rest of
            // the clip was then dropped, so the clip played silent until the
            // next seek happened to land better.
            if run.presentation.isValid, time + 0.001 < target { return }
            guard audioRuns.push(run, generation: run.generation) else { return }
            audioSeekTarget.withLock { $0 = nil }
            return
        }
        _ = audioRuns.push(run, generation: run.generation)
    }

    private func decodeAudioLoop() {
        // However this thread ends, it says that no more sound is coming.
        // Everything that decides a clip is over waits for both halves to run
        // out, so a thread that returns quietly leaves the clip unable ever to
        // finish: the picture stops on its last frame and the timeline counts
        // up for as long as anyone watches it.
        defer { audioRuns.finish() }

        guard let stream = demuxer.audioStream else { return }
        let decoder: AudioDecoder
        do {
            decoder = try AudioDecoder(stream: stream)
        } catch {
            // Sound that will not decode is not worth failing a clip over: the
            // picture is what the reader came for. It is worth saying so.
            MediaLog.decoder.error("the sound will not decode: \(String(describing: error), privacy: .public)")
            return
        }
        defer { decoder.close() }

        var lastGeneration = audioPackets.currentGeneration
        while !isStopped {
            let generation = audioPackets.currentGeneration
            if generation != lastGeneration {
                decoder.flush()
                lastGeneration = generation
            }

            switch audioPackets.pop() {
            case .item(let packet):
                try? decoder.decode(packet, generation: generation) { run in
                    self.emit(run)
                }
                if !hasVideo { reportSoundAsFirstFrame() }
            case .endOfStream:
                try? decoder.decode(nil, generation: generation) { run in
                    self.emit(run)
                }
                // Nothing is going to answer the seek now. Left set, it would
                // still be filtering sound after the clip was sent somewhere
                // else entirely.
                audioSeekTarget.withLock { $0 = nil }
                audioRuns.finish()
                guard audioPackets.waitForFlush(after: generation) else { return }
                decoder.flush()
                lastGeneration = audioPackets.currentGeneration
                continue
            case .closed:
                return
            }
        }
    }

    /// For a clip with no picture, the sound stands in for the first frame.
    private func reportSoundAsFirstFrame() {
        guard audioSeekTarget.withLock({ $0 }) == nil else { return }
        if let answered = gate.withLock({ $0.claimSeekReport() }) {
            onFirstFrame?(answered)
        } else if gate.withLock({ $0.claimPlainReport() }) {
            onFirstFrame?(nil)
        }
    }
}
