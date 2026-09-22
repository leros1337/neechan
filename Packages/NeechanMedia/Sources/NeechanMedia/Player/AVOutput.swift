import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Shows the pictures and plays the sound, on one clock.
///
/// The clock is the render synchronizer's, which slaves itself to the audio
/// renderer when there is one and runs on the host clock when there is not.
/// That is the whole reason this is built on Core Media's renderers rather
/// than on a timer: keeping picture and sound together over a long clip is
/// exactly the part that is easy to get subtly wrong, and the system already
/// does it.
///
/// Both renderers pull. They ask for media when they have room, on a queue of
/// their own, and take whatever the decode threads have put in the queues. A
/// callback that blocks would stall playback, so nothing here ever waits.
final class AVOutput: @unchecked Sendable {
    /// The layer the view puts on screen.
    let displayLayer = AVSampleBufferDisplayLayer()

    /// The player's name, so the status lines of two outputs can be told
    /// apart in a log. Written from the main actor, read on the output queue;
    /// a torn read of a short string is a misprint, not a fault.
    nonisolated(unsafe) var name = ""

    /// The layer's renderer, taken once and kept.
    ///
    /// `sampleBufferRenderer` belongs to the layer and is isolated to the
    /// main actor; the renderer it hands back is the half of the pair meant
    /// to be fed from a background thread, which is all this class ever does
    /// with it. Holding it is what lets everything below stay off the main
    /// actor.
    private let videoRenderer: AVSampleBufferVideoRenderer

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    /// Replaced on every flush rather than reused.
    ///
    /// An audio renderer drives the synchronizer's clock, and one that has
    /// already played a clip to its end puts the clock back where it left off
    /// however the clock is set afterwards. Seeking then lands correctly and
    /// is undone a moment later, which reads as a clip that refuses to be
    /// played again. Flushing it does not clear that; a new one has none of it.
    private var audioRenderer = AVSampleBufferAudioRenderer()
    private let queue = DispatchQueue(label: "io.neechan.media.output")

    private var videoFrames: BoundedQueue<DecodedFrame>?
    private var audioRuns: BoundedQueue<DecodedAudio>?
    private var progressObserver: Any?
    /// Whether the audio renderer is currently attached to the clock.
    ///
    /// Tracked because attaching one twice is a hard error, and a player whose
    /// clip is swapped out from under it goes through here again.
    private var isAudioAttached = false
    private var formatDescription: CMVideoFormatDescription?
    private var formatDescriptionSize: (width: Int, height: Int, format: OSType) = (0, 0, 0)

    private let state = Mutex(State())
    private struct State {
        /// The presentation time of the last thing handed to a renderer, so
        /// the end of the clip can be recognised when the clock reaches it.
        var lastVideoEnd: CMTime = .zero
        var lastAudioEnd: CMTime = .zero
        var hasEnded = false
        var hasVideo = false
        var hasAudio = false
        /// Whether the clock has already been told it ran out, so it is told
        /// once rather than ten times a second.
        var isStarved = false
        /// Set while the renderers are empty on purpose, between a seek and
        /// the first picture for where it landed. Nothing the clock does in
        /// that window means anything: it has been moved somewhere nothing has
        /// been shown yet, so it would read as having run out every time.
        var isAwaitingNewPosition = false
        /// The earliest thing handed to a renderer since playback ran out.
        ///
        /// Normally just ahead of the clock. When it is behind, the clock has
        /// got ahead of the media, and waiting for media to overtake it is
        /// waiting for something that will not happen.
        var earliestSinceStarved: CMTime = .invalid
        /// When playback ran out, so a wait that is going nowhere can be told
        /// apart from one that is simply taking a while.
        var starvedAt: ContinuousClock.Instant?
    }

    /// Called about ten times a second while the clock runs.
    var onProgress: (@Sendable (CMTime) -> Void)?
    /// Called once when the clock reaches the end of everything decoded.
    var onEnded: (@Sendable () -> Void)?
    /// Called when the renderers run dry before the file has ended.
    var onStarved: (@Sendable () -> Void)?
    /// Called when there is something to show again, so playing can carry on.
    ///
    /// Carries where to carry on from: usually nowhere in particular, but a
    /// clock that has got ahead of the media is sent back to meet it.
    var onRefilled: (@Sendable (CMTime) -> Void)?

    /// On the main actor because the layer's own properties are, and this is
    /// the one place they are touched. `MediaPlayer`, which owns the only
    /// output there is, is isolated there too.
    @MainActor
    init() {
        displayLayer.videoGravity = .resizeAspect
        videoRenderer = displayLayer.sampleBufferRenderer
        synchronizer.addRenderer(videoRenderer)
    }

    /// Starts pulling from these queues.
    func begin(video: BoundedQueue<DecodedFrame>?, audio: BoundedQueue<DecodedAudio>?) {
        videoFrames = video
        audioRuns = audio
        state.withLock {
            $0 = State()
            $0.hasVideo = video != nil
            $0.hasAudio = audio != nil
        }

        // A renderer that pulls stops asking once it is handed nothing, and
        // then nothing starts it again. Being told when media lands is what
        // keeps a clip playing past the first few seconds.
        video?.onItemQueued = { [weak self] in self?.pump() }
        audio?.onItemQueued = { [weak self] in self?.pump() }

        if audio != nil {
            attachFreshAudioRenderer()
        }
        if video != nil {
            videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                self?.feedVideo()
            }
        }
        startWatchingTheClock()
        startReportingStatus()
    }

    /// Stops everything and gives the renderers back.
    func stop() {
        statusTimer?.cancel()
        statusTimer = nil
        if let progressObserver {
            synchronizer.removeTimeObserver(progressObserver)
            self.progressObserver = nil
        }
        synchronizer.rate = 0
        videoRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        // The picture goes too. One player now serves every page of a
        // gallery, and a clip that took a while to open was shown, until its
        // own first picture arrived, wearing the last frame of the clip
        // before it.
        videoRenderer.flush(removingDisplayedImage: true) {}
        audioRenderer.flush()
        if isAudioAttached {
            // Removed as of now, not as of the start of the timeline: `.zero`
            // is a point on the clock, and by this time the clock has moved.
            synchronizer.removeRenderer(audioRenderer, at: synchronizer.currentTime())
            isAudioAttached = false
        }
        videoFrames = nil
        audioRuns = nil
    }

    /// Puts a brand new audio renderer on the clock, in place of whatever was
    /// there.
    ///
    /// Always a new one, never the same instance again. Removing a renderer
    /// from the synchronizer happens in its own time, and adding the same one
    /// back before that has finished is refused outright, which ends the
    /// process. A renderer that has already played a clip to its end also puts
    /// the clock back where it left off however the clock is set afterwards,
    /// which a new one does not.
    private func attachFreshAudioRenderer() {
        let muted = audioRenderer.isMuted
        let volume = audioRenderer.volume

        if isAudioAttached {
            audioRenderer.stopRequestingMediaData()
            audioRenderer.flush()
            synchronizer.removeRenderer(audioRenderer, at: synchronizer.currentTime())
            isAudioAttached = false
        }

        audioRenderer = AVSampleBufferAudioRenderer()
        audioRenderer.isMuted = muted
        audioRenderer.volume = volume
        synchronizer.addRenderer(audioRenderer)
        isAudioAttached = true
        audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.feedAudio()
        }
    }

    /// Says that the clock is about to be sent somewhere nothing has been
    /// enqueued for, so it should not be believed until something has.
    func awaitNewPosition() {
        state.withLock {
            $0.isAwaitingNewPosition = true
            $0.isStarved = false
        }
    }

    /// Asks the renderers to take whatever is waiting.
    ///
    /// Safe from any thread: the work happens on the output's own queue, which
    /// is the only place either renderer is fed.
    func pump() {
        queue.async { [weak self] in
            self?.feedVideo()
            self?.feedAudio()
        }
    }

    /// Throws away what the renderers are holding, after a seek.
    func flush() {
        videoRenderer.flush()
        if isAudioAttached {
            attachFreshAudioRenderer()
        }
        state.withLock {
            $0.lastVideoEnd = .zero
            $0.lastAudioEnd = .zero
            $0.hasEnded = false
            $0.isStarved = false
            $0.isAwaitingNewPosition = true
        }
        // Whatever was thrown away has to be replaced before the clock can
        // move again.
        pump()
    }

    /// Runs the clock, or stops it, from `time`.
    func setRate(_ rate: Float, time: CMTime) {
        let before = synchronizer.currentTime()
        if time.isValid {
            synchronizer.setRate(rate, time: time)
        } else {
            synchronizer.rate = rate
        }
        MediaLog.output.debug(
            """
            rate \(rate, privacy: .public) asked for             \(time.isValid ? TimeMath.seconds(time) : -1, format: .fixed(precision: 3), privacy: .public)s:             clock \(TimeMath.seconds(before), format: .fixed(precision: 3), privacy: .public)s             -> \(TimeMath.seconds(self.synchronizer.currentTime()), format: .fixed(precision: 3), privacy: .public)s
            """
        )
    }

    /// Whether the clip has run out of things to show and the clock has
    /// reached the last of them.
    ///
    /// Asked before playing, because the state machine is not always the one
    /// who noticed. A clip whose sound never said it had finished sat in
    /// `buffering` at the end of the file, and pressing play then ran the clock
    /// on over a frozen last frame instead of starting the clip again.
    var hasRunOut: Bool {
        // The queues first, never inside the state lock.
        let hasVideo = state.withLock { $0.hasVideo }
        let nothingMoreComing = hasVideo
            ? (videoFrames?.isDrained ?? true)
            : (audioRuns?.isDrained ?? true)
        guard nothingMoreComing else { return false }

        let last = state.withLock { current in
            max(
                current.hasVideo ? current.lastVideoEnd : .zero,
                current.hasAudio ? current.lastAudioEnd : .zero
            )
        }
        guard last.isValid, last > .zero else { return false }
        return synchronizer.currentTime() >= last
    }

    var rate: Float { synchronizer.rate }

    var currentTime: CMTime { synchronizer.currentTime() }

    var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    /// True when the picture has to be thrown away and decoded again, which is
    /// what coming back from the background sometimes asks for.
    var needsRestartAfterBackgrounding: Bool {
        videoRenderer.requiresFlushToResumeDecoding
    }

    // MARK: - Pulling

    /// Notices that media has arrived while playback was stopped for want of
    /// it, and says so.
    ///
    /// Has to be driven from the feeding side rather than from the clock. The
    /// clock is stopped while waiting, so the periodic observer that would
    /// have spotted the refill never fires again, and the clip waits for ever
    /// with everything it needs sitting in the renderer.
    private func noticeRefill() {
        let now = synchronizer.currentTime()
        let videoDone = videoFrames.map(\.isDrained) ?? true
        let audioDone = audioRuns.map(\.isDrained) ?? true

        enum Outcome { case resume(CMTime), reachedTheEnd }

        let outcome = state.withLock { current -> Outcome? in
            guard current.isStarved, !current.isAwaitingNewPosition else { return nil }
            let last = max(
                current.hasVideo ? current.lastVideoEnd : .zero,
                current.hasAudio ? current.lastAudioEnd : .zero
            )
            guard last.isValid else { return nil }

            // The clock has got ahead of everything there is to show, so it is
            // sent back to meet it. Otherwise it waits for media to overtake
            // it, which never happens, and the clip stops for good.
            let earliest = current.earliestSinceStarved
            if earliest.isValid, CMTimeGetSeconds(now - earliest) > 0.5, last <= now {
                current.isStarved = false
                current.earliestSinceStarved = .invalid
                current.starvedAt = nil
                return .resume(earliest)
            }

            let ahead = CMTimeGetSeconds(last - now)

            // A clip with a picture is over when the picture is. The sound
            // gets no vote: an audio queue that never says it has finished,
            // which a seek landing on the end of the file leaves behind, kept
            // the clip alive for ever over a frozen last frame.
            let nothingMoreComing = current.hasVideo ? videoDone : audioDone

            // Nothing left ahead of the clock and nothing more coming. That is
            // the end of the clip, not something to carry on with: starting
            // again here ran the clock off the end of the file with the last
            // picture frozen on screen and no way of ever stopping.
            if ahead <= 0, nothingMoreComing {
                current.isStarved = false
                current.earliestSinceStarved = .invalid
                current.starvedAt = nil
                current.hasEnded = true
                return .reachedTheEnd
            }

            // A quarter of a second in hand, so playing does not start again
            // only to stop on the very next frame. Less will do when there is
            // no more coming, because that is all there will ever be.
            guard ahead >= 0.25 || (ahead > 0 && nothingMoreComing) else { return nil }

            current.isStarved = false
            current.earliestSinceStarved = .invalid
            current.starvedAt = nil
            return .resume(.invalid)
        }

        if case .reachedTheEnd = outcome {
            MediaLog.output.debug(
                "nothing left at \(TimeMath.seconds(now), format: .fixed(precision: 3), privacy: .public)s; that was the end"
            )
            onEnded?()
            return
        }

        if case .resume(let resumeAt) = outcome {
            if resumeAt.isValid {
                MediaLog.output.warning(
                    """
                    the clock had run past the picture; going back to \
                    \(TimeMath.seconds(resumeAt), format: .fixed(precision: 3), privacy: .public)s
                    """
                )
            } else {
                MediaLog.output.debug(
                    "enough arrived at \(TimeMath.seconds(now), format: .fixed(precision: 3), privacy: .public)s"
                )
            }
            onRefilled?(resumeAt)
        }
    }

    private func feedVideo() {
        guard let videoFrames else { return }
        let renderer = videoRenderer
        if let failure = renderer.error {
            MediaLog.output.error(
                "the video renderer stopped: \(failure.localizedDescription, privacy: .public)"
            )
        }
        while renderer.isReadyForMoreMediaData {
            guard let frame = videoFrames.take() else {
                // Nothing ready. Whether that is the end of the clip or the
                // network falling behind is decided by the clock watcher,
                // which can see both queues and the demuxer.
                return
            }
            guard let sample = sampleBuffer(for: frame) else { continue }
            renderer.enqueue(sample)
            state.withLock {
                $0.isAwaitingNewPosition = false
                if $0.isStarved, !$0.earliestSinceStarved.isValid {
                    $0.earliestSinceStarved = frame.presentation
                }
                $0.lastVideoEnd = frame.duration.isValid
                    ? frame.presentation + frame.duration
                    : frame.presentation
            }
        }
        noticeRefill()
    }

    private func feedAudio() {
        guard let audioRuns else { return }
        while audioRenderer.isReadyForMoreMediaData {
            guard let run = audioRuns.take() else { return }
            audioRenderer.enqueue(run.sampleBuffer)
            state.withLock {
                if !$0.hasVideo { $0.isAwaitingNewPosition = false }
                $0.lastAudioEnd = run.presentation
                    + CMTime(seconds: run.mediaDuration, preferredTimescale: 48_000)
            }
        }
        noticeRefill()
    }

    /// Wraps a decoded picture in what the renderer takes.
    private func sampleBuffer(for frame: DecodedFrame) -> CMSampleBuffer? {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)

        // Remade only when the picture changes shape, which within one clip it
        // does not.
        if formatDescription == nil || formatDescriptionSize != (width, height, format) {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &created
            ) == noErr else { return nil }
            formatDescription = created
            formatDescriptionSize = (width, height, format)
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: frame.duration.isValid ? frame.duration : .invalid,
            presentationTimeStamp: frame.presentation,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    // MARK: - The clock

    /// A line every couple of seconds saying where playback is and how much it
    /// has in hand.
    ///
    /// The one line worth having when a clip stutters: whether the queues are
    /// empty tells apart a decoder that cannot keep up from bytes that are not
    /// arriving, and neither is obvious from the stopping itself.
    /// On a timer of its own rather than on the clock.
    ///
    /// The clock stops when playback does, and a clip that has stopped and not
    /// started again is exactly the thing worth looking at. Reporting from the
    /// clock meant the log went silent at the only moment it mattered.
    private func startReportingStatus() {
        statusTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.reportStatus() }
        timer.resume()
        statusTimer = timer
    }

    private func reportStatus() {
        let time = synchronizer.currentTime()
        // Asked again on every report, because the usual prompt is a push onto
        // a queue and the decode thread stops pushing the moment that queue is
        // full. A clip stopped with its queues full got no further chances at
        // all, which is exactly when it most needed one.
        noticeRefill()
        checkForAWaitGoingNowhere(at: time)
        MediaLog.output.debug(
            """
            [\(self.name, privacy: .public)] at \(TimeMath.seconds(time), format: .fixed(precision: 1), privacy: .public)s, \
            rate \(self.synchronizer.rate, format: .fixed(precision: 0), privacy: .public), \
            video \(self.videoFrames?.buffered ?? 0, format: .fixed(precision: 2), privacy: .public)s and \
            audio \(self.audioRuns?.buffered ?? 0, format: .fixed(precision: 2), privacy: .public)s in hand, \
            drained video \(self.videoFrames?.isDrained ?? true, privacy: .public) \
            audio \(self.audioRuns?.isDrained ?? true, privacy: .public), \
            waiting \(self.state.withLock { $0.isStarved }, privacy: .public), \
            for a new position \(self.state.withLock { $0.isAwaitingNewPosition }, privacy: .public), \
            renderer ready \(self.videoRenderer.isReadyForMoreMediaData, privacy: .public)
            """
        )
    }

    /// Rescues a clip that has stopped and cannot start itself again.
    ///
    /// Two shapes, both of which used to wait for ever; `StallRecovery` holds
    /// the reasoning and the cases. Recovery from the first is to throw away
    /// what the renderers hold and start again from the picture that is
    /// actually next; from the second, to say that the clip is over.
    private func checkForAWaitGoingNowhere(at time: CMTime) {
        // Read before the state lock is taken, never inside it: these take the
        // queues' own lock, and holding two locks at once here would be the
        // one place in the player that could ever deadlock on itself.
        let nextPicture = videoFrames?.peek()?.presentation
        let isVideoDrained = videoFrames?.isDrained ?? true
        let isAudioDrained = audioRuns?.isDrained ?? true
        let isRendererReady = videoRenderer.isReadyForMoreMediaData
        let isClockRunning = synchronizer.rate > 0

        let situation = state.withLock { current in
            StallRecovery.Situation(
                isStarved: current.isStarved,
                isAwaitingNewPosition: current.isAwaitingNewPosition,
                hasEnded: current.hasEnded,
                stoppedFor: current.starvedAt.map { ContinuousClock.now - $0 },
                clock: time,
                lastHandedOver: max(
                    current.hasVideo ? current.lastVideoEnd : .zero,
                    current.hasAudio ? current.lastAudioEnd : .zero
                ),
                nextPicture: nextPicture,
                isRendererReady: isRendererReady,
                isVideoDrained: isVideoDrained,
                isAudioDrained: isAudioDrained,
                isClockRunning: isClockRunning,
                hasVideo: current.hasVideo
            )
        }

        switch StallRecovery.decide(situation) {
        case .waitLonger:
            return

        case .reachedTheEnd:
            state.withLock { $0.hasEnded = true }
            MediaLog.output.warning(
                """
                nothing left at \(TimeMath.seconds(time), format: .fixed(precision: 1), privacy: .public)s \
                and nothing more coming; calling it finished
                """
            )
            onEnded?()

        case .startAgain(let picture):
            state.withLock {
                $0.isStarved = false
                $0.earliestSinceStarved = .invalid
                $0.starvedAt = nil
            }
            MediaLog.output.warning(
                """
                stopped for \(situation.stoppedFor?.seconds ?? 0, format: .fixed(precision: 1), privacy: .public)s \
                with the picture at \
                \(TimeMath.seconds(picture), format: .fixed(precision: 3), privacy: .public)s \
                and the clock at \(TimeMath.seconds(time), format: .fixed(precision: 3), privacy: .public)s, \
                renderer ready \(situation.isRendererReady, privacy: .public); starting again from the picture
                """
            )
            onRefilled?(picture)
        }
    }

    private var statusTimer: DispatchSourceTimer?

    private func startWatchingTheClock() {
        progressObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: queue
        ) { [weak self] time in
            self?.clockMoved(to: time)
        }
    }

    private func clockMoved(to time: CMTime) {
        onProgress?(time)

        let video = videoFrames
        let audio = audioRuns
        // Everything that will ever arrive has arrived and been handed over.
        let videoDone = video.map(\.isDrained) ?? true
        let audioDone = audio.map(\.isDrained) ?? true

        let (ended, starved, refilled) = state.withLock { current -> (Bool, Bool, Bool) in
            guard !current.hasEnded, !current.isAwaitingNewPosition else {
                return (false, false, false)
            }

            let last = max(
                current.hasVideo ? current.lastVideoEnd : .zero,
                current.hasAudio ? current.lastAudioEnd : .zero
            )
            guard last.isValid, last > .zero else { return (false, false, false) }

            let nothingMoreComing = current.hasVideo ? videoDone : audioDone

            if nothingMoreComing, time >= last {
                current.hasEnded = true
                return (true, false, false)
            }
            // Past everything handed over, with more of the file still to
            // come: the network is behind rather than the clip being over.
            if time >= last, !nothingMoreComing {
                guard !current.isStarved else { return (false, false, false) }
                current.isStarved = true
                current.earliestSinceStarved = .invalid
                current.starvedAt = ContinuousClock.now
                return (false, true, false)
            }
            // Something has been handed over past where the clock had got to,
            // so there is a picture to show again. Reported only after having
            // said it ran out, which is what stops the two chasing each other
            // ten times a second.
            if current.isStarved {
                current.isStarved = false
                return (false, false, true)
            }
            return (false, false, false)
        }

        if ended {
            MediaLog.output.debug(
                """
                clock reached \(TimeMath.seconds(time), format: .fixed(precision: 3), privacy: .public)s                 with everything drained
                """
            )
            onEnded?()
        }
        if starved {
            MediaLog.output.debug(
                """
                starved at \(TimeMath.seconds(time), format: .fixed(precision: 3), privacy: .public)s,                 video queued \(video?.buffered ?? 0, format: .fixed(precision: 3), privacy: .public)s,                 audio queued \(audio?.buffered ?? 0, format: .fixed(precision: 3), privacy: .public)s
                """
            )
            onStarved?()
            // Asking again costs nothing and covers the case where media
            // landed between the renderer giving up and this noticing.
            pump()
        }
        if refilled {
            MediaLog.output.debug(
                "carrying on from \(TimeMath.seconds(time), format: .fixed(precision: 3), privacy: .public)s"
            )
            onRefilled?(.invalid)
        }
    }
}
