import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import NeechanAPI

/// Plays one video at a time.
///
/// Everything above this sees only what it asks for and what it is told:
/// a URL and some options in, a `PlaybackState` and a `PlaybackProgress` out.
/// The threads, the decoders and the clock are all behind it.
///
/// One player can outlive the clip it is showing. A feed that swaps the URL
/// under a single player keeps its layer, its clock and its mute setting, and
/// only the pipeline underneath is replaced.
@MainActor
public final class MediaPlayer {
    private let output = AVOutput()
    private var pipeline: Pipeline?
    private var machine = PlaybackStateMachine()
    private var options = MediaPlayerOptions(kind: .webmVideo)
    /// Bumped on every load, so a pipeline that finishes opening after the
    /// reader has moved on is thrown away rather than shown.
    private var loadCount = 0

    /// Told whenever what the player is doing changes.
    public var onState: ((PlaybackState) -> Void)?
    /// Told about ten times a second while the clip runs.
    public var onProgress: ((PlaybackProgress) -> Void)?

    /// A short name for this player, so two of them can be told apart in a log.
    public private(set) var name: String
    private let shortName = String(UUID().uuidString.prefix(4))
    /// Who this player is to whatever shares the sound between players.
    ///
    /// Not the object's own identity: one that has gone is said so from
    /// `deinit`, a moment later, and by then another player can be living at
    /// the same address.
    let soundID = UUID()
    /// Whether this player currently holds a clip, for the count of how many
    /// are loaded at once.
    ///
    /// Behind a lock rather than a plain property because `deinit` reads it,
    /// and a deinitialiser does not run on the main actor however the rest of
    /// this class is isolated.
    private let isLoaded = Mutex(false)

    public init() {
        name = shortName
        output.onProgress = { [weak self] time in
            Task { @MainActor in self?.progressed(to: time) }
        }
        output.onEnded = { [weak self] in
            Task { @MainActor in self?.reachedTheEnd() }
        }
        output.onStarved = { [weak self] in
            Task { @MainActor in self?.ranDry() }
        }
        output.onRefilled = { [weak self] resumeAt in
            Task { @MainActor in self?.filledUpAgain(from: resumeAt) }
        }
    }

    deinit {
        if isLoaded.withLock({ $0 }) { LoadedPlayers.unloaded() }
        // The reading and decoding threads do not hold this object, so it can
        // be let go of while they are still running, and then nothing is left
        // to stop them: they carry on fetching, holding a connection the clip
        // actually on screen is waiting for. A view that disappears without
        // saying so leaves exactly that behind.
        pipeline?.cancel()
        output.stop()
        // Nor is it told to give the sound back, and music another app was
        // playing would otherwise stay stopped for a clip nobody can hear.
        let soundID = soundID
        Task { @MainActor in PlaybackEnvironment.playerGone(soundID) }
    }

    /// Says where this player came from, so a log that shows two of them says
    /// which views asked for them.
    public func describe(as origin: String) {
        // Replaces rather than appends: a view describes its player each time
        // it appears, and a paged gallery makes one view appear many times.
        name = "\(shortName) \(origin)"
        output.name = name
    }

    /// The layer a view puts on screen.
    public var displayLayer: AVSampleBufferDisplayLayer { output.displayLayer }

    /// How far the picture has to be turned to be the right way up.
    public private(set) var rotationDegrees: Double = 0
    /// The picture's size, before rotation.
    public private(set) var naturalSize: CGSize = .zero
    /// True once a picture has come back from the graphics hardware rather
    /// than the CPU. For diagnostics.
    public var isDecodingInHardware: Bool { pipeline?.isDecodingInHardware ?? false }

    /// What the open file turned out to hold, for diagnostics.
    var containerName: String? { pipeline?.containerName }
    var videoCodecName: String? { pipeline?.videoCodecName }
    var audioCodecName: String? { pipeline?.audioCodecName }
    /// Nil when the clip has no sound to decode; false when it has, and none
    /// has come out of the decoder.
    var hasDecodedSound: Bool? {
        guard let pipeline, pipeline.hasAudio else { return nil }
        return pipeline.hasDecodedSound
    }

    public private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            MediaLog.player.debug(
                """
                [\(self.name, privacy: .public)] \(String(describing: oldValue), privacy: .public) \
                -> \(String(describing: self.state), privacy: .public)
                """
            )
            PlaybackEnvironment.keepScreenAwake(state == .playing)
            reportSound()
            // A clip that is waiting wants the whole connection to itself, so
            // anything being fetched ahead of it gives way.
            PlaybackDemand.setWaitingForBytes(state == .buffering || state == .preparing)
            onState?(state)
        }
    }

    /// Opens a file and, unless told otherwise, starts playing it.
    public func load(url: URL, options: MediaPlayerOptions) {
        load(url: url, options: options, session: PlaybackSession.shared)
    }

    /// The same, reading through a session of the caller's choosing and in
    /// pieces of a size it chooses.
    ///
    /// For the tests, which need a source slow enough to make playback run out
    /// of media. A local file never does, and neither does a small file
    /// fetched in one piece however slow the server.
    func load(
        url: URL, options: MediaPlayerOptions, session: URLSession, blockSize: Int? = nil
    ) {
        // The clip this player already holds. A paged gallery can build two
        // views for the one page it lands on, fifty milliseconds apart, and
        // both ask for the clip; the second request used to throw away the
        // first's work and open the file again. Not a failed clip, though:
        // asking for that again is asking for another try.
        if self.url == url, isLoaded.withLock({ $0 }), !isFailed, state != .idle {
            MediaLog.player.debug(
                "[\(self.name, privacy: .public)] already holds \(url.lastPathComponent, privacy: .public)"
            )
            return
        }

        stopClip()
        self.url = url

        output.name = name
        self.options = options
        machine = PlaybackStateMachine(autoplays: options.autoplays, isLooping: options.loops)
        pendingSeekTarget = nil
        shouldResumeAfterSeek = true

        // Back to the beginning, stopped, before anything else. A feed that
        // swaps the clip under one player leaves the clock wherever the last
        // one got to, and a new clip whose pictures start at zero then arrives
        // entirely in the past: the renderer fills with frames it will never
        // show, stops asking for more, and the clip never starts.
        output.awaitNewPosition()
        output.setRate(0, time: .zero)

        MediaLog.player.debug("[\(self.name, privacy: .public)] loading \(url.lastPathComponent, privacy: .public)")
        let wasLoaded = isLoaded.withLock { current -> Bool in
            defer { current = true }
            return current
        }
        if !wasLoaded { LoadedPlayers.loaded(name) }

        state = machine.handle(.opened)
        // Also when the state has not changed, which reports nothing: one
        // clip still being opened replaced by another.
        reportSound()
        loadCount += 1
        let load = loadCount

        // Opening reads the header, which for a remote file means waiting on
        // the network. Never on the main actor.
        let source: MediaSource
        if url.isFileURL {
            source = .file(url)
        } else {
            let reader = MediaRangeReader(
                url: url,
                headers: options.httpHeaders,
                session: session,
                store: .shared,
                blockSize: blockSize,
                readAheadBlocks: Self.readAheadBlocks
            )
            // Kept so that a clip left before it has opened can be given up
            // on. Until the file opens there is no pipeline to cancel, and a
            // reader waiting on a slow connection went on holding it for the
            // clip that had replaced this one.
            self.reader = reader
            source = .remote(reader)
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let pipeline = try Pipeline(source: source)
                await self?.attach(pipeline, forLoad: load)
            } catch {
                await self?.failed("\(error)", forLoad: load)
            }
        }
    }

    /// The clip this player holds, until it is unloaded.
    public private(set) var url: URL?

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// The bytes of the clip being opened or played, if it is remote.
    private var reader: MediaRangeReader?

    /// Stops and gives everything back, keeping the layer and its settings.
    public func unload() {
        stopClip()
        // The state is left as it was, so it says nothing by changing.
        reportSound()
    }

    private func stopClip() {
        url = nil
        reader?.giveUp()
        reader = nil
        let wasLoaded = isLoaded.withLock { current -> Bool in
            defer { current = false }
            return current
        }
        if wasLoaded { LoadedPlayers.unloaded() }
        pipeline?.cancel()
        pipeline = nil
        output.stop()
        PlaybackEnvironment.keepScreenAwake(false)
    }

    /// Stops for good.
    public func shutdown() {
        stopClip()
        // The sound goes back at once rather than after the moment a pause
        // waits: nothing is going to play next.
        PlaybackEnvironment.playerGone(soundID)
    }

    public func play() {
        guard state != .failed("") else { return }
        // No taking the sound here. The state this leads to says whether the
        // clip is heard, and only then is the sound taken from other apps.

        // Asked to play before there is anything to play. Starting the clock
        // now would run it against an empty renderer while the file is still
        // being opened, so this only says that it should start once there is
        // a picture, which is what the first one does.
        if state == .preparing || state == .idle {
            machine.autoplays = true
            reportSound()
            return
        }

        // `finished` is the tidy way a clip ends; `hasRunOut` is the untidy
        // one. A clip can reach the end of the file while still waiting for
        // sound that never arrives, and it then sits in `buffering` with
        // nothing left to show. Playing either starts it again, which is what
        // every video player does and what the viewer's button means.
        if state == .finished || output.hasRunOut {
            restart()
            return
        }
        // Undoes what `pause` told a seek still under way, so its picture
        // starts the clock rather than stopping it again.
        shouldResumeAfterSeek = true
        output.setRate(1, time: .invalid)
        state = machine.handle(.play)
    }

    public func pause() {
        output.setRate(0, time: .invalid)
        // A seek still waiting for its picture would otherwise start the clock
        // again when the picture came, undoing this. A loop is a seek to the
        // start, so leaving the app just as a clip came round did exactly that.
        shouldResumeAfterSeek = false
        state = machine.handle(.pause)
    }

    /// The app has gone to the background.
    ///
    /// A clip that is playing, or about to, is paused, and stays paused when
    /// the reader comes back. Nothing here starts it again: a video that picks
    /// up by itself as the app returns makes a noise nobody asked for.
    ///
    /// The sound goes back to other apps at once, not after the moment an
    /// ordinary pause waits, which a suspended app may never get to.
    public func pauseForBackground() {
        defer { PlaybackEnvironment.appWentToBackground() }
        guard state.pausesWhenAppLeaves else { return }
        MediaLog.player.debug("[\(self.name, privacy: .public)] pausing: the app went to the background")
        pause()
    }

    /// Another app has taken the sound: a phone call, or music started from
    /// Control Centre.
    ///
    /// Paused, as the system's own player does, and left paused until the
    /// reader plays it again. Carrying on would show a picture with no sound
    /// under a button that says the sound is on.
    func pauseForInterruption() {
        guard state.pausesWhenAppLeaves else { return }
        MediaLog.player.debug("[\(self.name, privacy: .public)] pausing: another app took the sound")
        pause()
    }

    public func seek(to time: TimeInterval) {
        guard let pipeline else { return }
        MediaLog.player.debug(
            "[\(self.name, privacy: .public)] seeking to \(time, format: .fixed(precision: 3), privacy: .public)s"
        )

        // Anything but a deliberate pause resumes. Reading `playing` alone got
        // this wrong: a seek that landed while the clip was buffering left it
        // stopped for good, which is what scrubbing does over and over.
        shouldResumeAfterSeek = state != .paused
        pendingSeekTarget = time
        output.awaitNewPosition()

        // Stopped, and moved to where the reader asked in the same breath.
        // Moving it only once a picture arrives does not work after a clip has
        // run to its end: the renderers have finished, and the clock then
        // refuses to go backwards, so the seek lands and the clip is declared
        // over again immediately.
        output.setRate(0, time: CMTime(seconds: time, preferredTimescale: 600))
        // The queues first, then the renderers. The other way round, flushing
        // the renderers pulls whatever is still queued from the old position
        // straight back into them.
        pipeline.seek(to: time)
        output.flush()
    }

    /// How far ahead of the demuxer to fetch, in blocks of a megabyte.
    ///
    /// Four is a few seconds of a phone-sized clip. Without any, the demuxer
    /// stops at every block boundary to wait out a round trip, and a clip that
    /// the connection could easily carry still plays in fits and starts.
    static let readAheadBlocks = 4

    /// Where a seek is heading, until a picture for it arrives.
    private var pendingSeekTarget: TimeInterval?
    /// Whether that seek should start playing when it gets there.
    private var shouldResumeAfterSeek = true

    public var isMuted: Bool {
        get { output.isMuted }
        set {
            output.isMuted = newValue
            reportSound()
        }
    }

    /// Tells whatever shares the sound between players, and with other apps,
    /// whether this one is being heard.
    ///
    /// From what the output is actually doing rather than what the screen
    /// above asked for: a clip muted there but not here is still heard.
    private func reportSound() {
        PlaybackEnvironment.report(SoundStatus(
            state: state,
            isMuted: output.isMuted,
            hasAudio: pipeline?.hasAudio,
            autoplays: machine.autoplays,
            isLoaded: url != nil
        ), from: self)
    }

    public func setLooping(_ looping: Bool) {
        machine.isLooping = looping
        // Turning looping on after the clip already ended starts it again
        // rather than waiting for an end that has been and gone.
        if looping, state == .finished { restart() }
    }

    // MARK: - What the machinery reports

    private func attach(_ pipeline: Pipeline, forLoad load: Int) {
        guard load == loadCount else {
            // The reader moved on while this was opening.
            pipeline.cancel()
            return
        }

        self.pipeline = pipeline
        naturalSize = pipeline.naturalSize
        rotationDegrees = pipeline.rotationDegrees

        pipeline.onFirstFrame = { [weak self] seek in
            Task { @MainActor in self?.firstFrameArrived(forLoad: load, answering: seek) }
        }
        pipeline.onFailed = { [weak self] message in
            Task { @MainActor in self?.failed(message, forLoad: load) }
        }

        output.isMuted = options.startsMuted
        // Now that the file has said whether it holds any sound. One with
        // none, or one starting muted, leaves other apps' music playing.
        reportSound()
        output.begin(
            video: pipeline.hasVideo ? pipeline.videoFrames : nil,
            audio: pipeline.hasAudio ? pipeline.audioRuns : nil
        )
        pipeline.start()
    }

    private func firstFrameArrived(forLoad load: Int, answering seek: TimeInterval?) {
        guard load == loadCount else { return }

        // After a seek rather than after opening: the clock is moved to where
        // the reader asked for and started there, now that there is something
        // to show at it.
        if let target = pendingSeekTarget {
            // Only a picture for this seek will do. A report for an earlier
            // one, or for the opening of the clip, arriving after the reader
            // has moved on says nothing about where the clock should be now.
            guard let seek, abs(seek - target) < 0.001 else {
                MediaLog.player.debug(
                    """
                    [\(self.name, privacy: .public)] a picture for                     \(seek.map { String(format: "%.3fs", $0) } ?? "the start", privacy: .public)                     arrived while waiting for \(target, format: .fixed(precision: 3), privacy: .public)s; ignored
                    """
                )
                return
            }
            pendingSeekTarget = nil
            output.setRate(
                shouldResumeAfterSeek ? 1 : 0,
                time: CMTime(seconds: target, preferredTimescale: 600)
            )
            if shouldResumeAfterSeek { state = machine.handle(.play) }
            return
        }

        state = machine.handle(.firstFrame)
        output.setRate(state == .playing ? 1 : 0, time: .zero)
    }

    private func failed(_ message: String, forLoad load: Int) {
        guard load == loadCount else { return }
        // What the reader is shown is the same sentence whatever went wrong.
        // The detail goes to the diagnostics, which is where it is useful.
        state = machine.handle(.failed(
            String(localized: "Playback failed.", bundle: .module.forAppLanguage(), locale: AppLocale.current)
        ))
        lastFailure = message
        MediaLog.player.error("failed: \(message, privacy: .public)")
    }

    /// The engine's own words about the last failure, for diagnostics.
    public private(set) var lastFailure: String?

    private func progressed(to time: CMTime) {
        guard state != .idle else { return }
        onProgress?(PlaybackProgress(
            current: TimeMath.seconds(time),
            total: pipeline?.duration ?? 0
        ))
    }

    /// Media has arrived past where the clock had got to.
    ///
    /// Deliberately not done on every progress report: resuming whether or not
    /// anything had arrived put the player into a loop, stopping and starting
    /// hundreds of times a second while the picture stayed still.
    private func filledUpAgain(from resumeAt: CMTime) {
        // Not while a seek is still finding its first picture. Starting the
        // clock then runs it forward while the decoder is still catching up,
        // and every frame it produces arrives already too late to show.
        guard pendingSeekTarget == nil, state == .buffering else { return }

        if resumeAt.isValid {
            // The clock had run past the picture. Moving it back is not enough
            // on its own: the renderers hold what they were given and will not
            // let the clock go behind it, so they are emptied first and filled
            // again from where the picture actually is.
            output.flush()
        }
        output.setRate(1, time: resumeAt)
        state = machine.handle(.refilled)
    }

    private func reachedTheEnd() {
        MediaLog.output.debug("reached the end, looping: \(self.machine.isLooping, privacy: .public)")
        guard machine.isLooping else {
            output.setRate(0, time: .invalid)
            state = machine.handle(.endOfStream)
            PlaybackEnvironment.keepScreenAwake(false)
            return
        }
        // A looping clip never reports that it finished: it simply starts
        // again, so the picture never goes away between repeats.
        restart()
        state = machine.handle(.endOfStream)
    }

    private func ranDry() {
        // A seek empties everything by design; that is not running dry.
        guard pendingSeekTarget == nil, state == .playing else { return }
        MediaLog.output.debug("ran out of decoded media, waiting for more")
        output.setRate(0, time: .invalid)
        state = machine.handle(.starved)
    }

    /// Plays the clip again from the beginning.
    ///
    /// Goes back through the same waiting the reader's own seeks do: the clock
    /// stays stopped until there is a picture for the start of the file.
    /// Starting it first showed the first frame and nothing after it, because
    /// the clock ran on while the decoders were still catching up.
    private func restart() {
        guard let pipeline else { return }
        MediaLog.player.debug("starting again from the beginning")
        shouldResumeAfterSeek = true
        pendingSeekTarget = 0
        output.setRate(0, time: .invalid)
        pipeline.seek(to: 0)
        output.flush()
        state = machine.handle(.play)
    }

}
