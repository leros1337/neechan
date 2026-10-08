import CoreGraphics
import CoreMedia
import Foundation
import Libavcodec
import Libavformat
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
    private let seekRequest = Mutex(SeekRequest())

    /// What the reading thread is asked to do about seeking.
    ///
    /// A seek is announced in two steps, and the reading thread looks at both.
    /// `epoch` moves the moment one begins, so a packet whose read overlapped
    /// it is known to come from where the clip was. `target` is published only
    /// once the queues have been emptied, so the generation the thread stamps
    /// on the packets of the new position is the queues' new one.
    private struct SeekRequest {
        var target: TimeInterval?
        var epoch = 0
        /// Between the two steps: the queues are being emptied, and nothing
        /// read now belongs anywhere.
        var isUnderway = false
    }
    /// How many pictures were decoded and thrown away getting back to where
    /// the reader asked for, which is how far the keyframe was behind it.
    private let droppedSinceSeek = Mutex(0)

    /// Called when there is something to show: once after opening, and once
    /// after every seek, with the seek's target so a report can be matched to
    /// the seek it answers rather than taken for a later one.
    var onFirstFrame: (@Sendable (_ picture: FirstPicture) -> Void)?

    /// What there is to show, once there is something.
    struct FirstPicture: Sendable {
        /// The seek this answers, or nil for the opening of the clip.
        let forSeek: TimeInterval?
        /// When the picture is to be shown. Usually a little after the seek's
        /// target, since the target rarely falls exactly on a picture, and a
        /// clock stopped at the target would never show it.
        let presentation: CMTime
        /// The last picture decoded and thrown away on the way to the target:
        /// the one before this. The only record of it there is, since it never
        /// reaches the renderer, and what a step back from here goes back to.
        let previous: CMTime?
    }
    /// Called if decoding fails outright.
    var onFailed: (@Sendable (String) -> Void)?

    var duration: TimeInterval { demuxer.duration }
    var naturalSize: CGSize { demuxer.naturalSize }
    var rotationDegrees: Double { demuxer.rotationDegrees }
    var hasVideo: Bool { videoStreamIndex != nil }
    var hasAudio: Bool { audioStreamIndex != nil }

    /// What the file turned out to be, for diagnostics.
    var containerName: String { demuxer.containerName }
    var videoCodecName: String? { Self.codecName(of: demuxer.videoStream) }
    var audioCodecName: String? { Self.codecName(of: demuxer.audioStream) }

    private static func codecName(of stream: UnsafeMutablePointer<AVStream>?) -> String? {
        guard let parameters = stream?.pointee.codecpar else { return nil }
        return String(cString: avcodec_get_name(parameters.pointee.codec_id))
    }

    /// Whether any sound has come out of the decoder yet.
    ///
    /// Having a sound stream is not the same thing. A decoder that will not
    /// open, or one whose every run is refused on the way out, leaves the clip
    /// playing in silence, and nothing else about it looks wrong.
    var hasDecodedSound: Bool { decodedSound.withLock { $0 } }
    private let decodedSound = Mutex(false)

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
        seekRequest.withLock {
            $0.epoch += 1
            $0.isUnderway = true
        }
        // Cut short whatever read is in flight so the seek is answered now
        // rather than whenever the network gets round to answering.
        //
        // Before the target is set, never after. The reading thread clears the
        // lever as it takes a target; pulled after that, it landed on the
        // reads of the very seek it was announcing, and nothing came round to
        // make that seek again.
        demuxer.interruptForSeek()
        videoPackets.flush()
        audioPackets.flush()
        videoFrames.flush()
        audioRuns.flush()
        // After the queues, never before. A packet is stamped with the
        // generation its queue has when the reading thread starts on it, and
        // one read from the old position just as a seek began was stamped
        // with the new generation, decoded, and taken for the seek's answer: a
        // step back from 5.93s landed at 6.67s, and everything after it came
        // from the keyframe at the start of the clip.
        seekRequest.withLock {
            $0.target = time
            $0.isUnderway = false
        }
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
            let request = seekRequest.withLock { request -> SeekRequest in
                let taken = request
                if !request.isUnderway { request.target = nil }
                return taken
            }
            // A seek between its two steps: the queues are being emptied.
            // Over in a moment, and nothing read before it is over belongs
            // anywhere.
            if request.isUnderway {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            if let target = request.target {
                demuxer.resumeAfterSeek()
                let moved = demuxer.seek(to: target)
                MediaLog.demuxer.debug(
                    """
                    moved to \(target, format: .fixed(precision: 3), privacy: .public)s:                     \(moved ? "yes" : "no", privacy: .public)
                    """
                )
                droppedSinceSeek.withLock { $0 = 0 }
            }

            // Taken before the read, so a seek that empties the queues while
            // it is under way leaves this packet stamped with the generation
            // the queues have just left behind, where it is refused.
            let videoGeneration = videoPackets.currentGeneration
            let audioGeneration = audioPackets.currentGeneration

            switch demuxer.read() {
            case .packet(let packet):
                // A seek began while this was being read, so it is from where
                // the clip was. The loop comes round to make the seek.
                guard seekRequest.withLock({ $0.epoch }) == request.epoch else { continue }
                if packet.streamIndex == videoStreamIndex {
                    videoPackets.push(packet, generation: videoGeneration)
                } else if packet.streamIndex == audioStreamIndex {
                    audioPackets.push(packet, generation: audioGeneration)
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
            // The generation comes with the packet, never ahead of it: see
            // `popStamped`. Asked for first, a seek in between had the new
            // position's keyframe decoded as the old position's and thrown
            // away, and the decoder reset just after, so nothing decoded until
            // the next keyframe.
            let (next, generation) = videoPackets.popStamped()
            if generation != lastGeneration {
                // A seek happened, or the clip is being played again after
                // its end was drained. Whatever the decoder is holding belongs
                // to the old position.
                decoder.flush()
                lastBeforeSeek = nil
                lastGeneration = generation
            }

            switch next {
            case .item(let packet):
                decodeVideo(packet, with: decoder, generation: generation)
            case .endOfStream:
                // Drain: a stream with B-frames holds its last pictures back
                // until it is told there is nothing more coming.
                try? decoder.decode(nil, generation: generation) { emit($0) }
                answerSeekWithTheLastPicture()
                videoFrames.finish()
                // Then wait to be sent round again rather than ending here.
                // The next packet comes under a new generation, which resets
                // the decoder.
                guard videoPackets.waitForFlush(after: generation) else { return }
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
                if time < target { lastBeforeSeek = frame }
                return
            }
            let previous = lastBeforeSeek?.presentation
            lastBeforeSeek = nil
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
            onFirstFrame?(FirstPicture(forSeek: answered, presentation: frame.presentation, previous: previous))
            return
        }

        guard videoFrames.push(frame, generation: frame.generation) else { return }
        // Claimed after the push, under the same lock a seek uses: a picture
        // of the old position whose push straddled a seek is refused here,
        // where it used to be taken for the seek's first picture.
        if gate.withLock({ $0.claimPlainReport() }) {
            onFirstFrame?(FirstPicture(forSeek: nil, presentation: frame.presentation, previous: nil))
        }
    }

    /// The last picture thrown away on the way to a seek's target, in case
    /// nothing at or after the target ever arrives. Only the video thread
    /// touches it.
    private nonisolated(unsafe) var lastBeforeSeek: DecodedFrame?

    /// Answers a seek that the file ran out before reaching.
    ///
    /// A seek to the very end of a clip, or into the part of a cut-off file
    /// that is not there, has no picture at or after its target. Nothing was
    /// ever announced for it, so the player waited for one for as long as
    /// anyone watched, over a frozen frame. The last picture there is stands
    /// in, shown at the target: it is what the end of the clip looks like, and
    /// the clip is over once it has been shown.
    private func answerSeekWithTheLastPicture() {
        defer { lastBeforeSeek = nil }
        guard let target = gate.withLock({ $0.seekTarget }), let last = lastBeforeSeek else { return }
        let shown = DecodedFrame(
            pixelBuffer: last.pixelBuffer,
            presentation: CMTime(seconds: target, preferredTimescale: 90_000),
            duration: last.duration,
            generation: last.generation
        )
        guard videoFrames.push(shown, generation: shown.generation) else { return }
        guard let answered = gate.withLock({ $0.claimSeekReport() }) else { return }
        MediaLog.decoder.debug(
            """
            the file ran out before \(target, format: .fixed(precision: 3), privacy: .public)s; \
            showing its last picture, from \(TimeMath.seconds(last.presentation), format: .fixed(precision: 3), privacy: .public)s
            """
        )
        onFirstFrame?(FirstPicture(forSeek: answered, presentation: shown.presentation, previous: nil))
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
        decodedSound.withLock { $0 = true }
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
            // As for the picture: the generation comes with the packet.
            let (next, generation) = audioPackets.popStamped()
            if generation != lastGeneration {
                decoder.flush()
                lastGeneration = generation
            }

            switch next {
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
                continue
            case .closed:
                return
            }
        }
    }

    /// For a clip with no picture, the sound stands in for the first frame.
    private func reportSoundAsFirstFrame() {
        guard audioSeekTarget.withLock({ $0 }) == nil else { return }
        // There is no picture to time, so the sound is said to start where
        // it was asked to, which is where the player puts the clock anyway.
        if let answered = gate.withLock({ $0.claimSeekReport() }) {
            onFirstFrame?(FirstPicture(forSeek: answered, presentation: .invalid, previous: nil))
        } else if gate.withLock({ $0.claimPlainReport() }) {
            onFirstFrame?(FirstPicture(forSeek: nil, presentation: .invalid, previous: nil))
        }
    }
}
