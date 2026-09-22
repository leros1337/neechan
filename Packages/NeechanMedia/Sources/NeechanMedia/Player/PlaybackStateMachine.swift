import Foundation

/// What the player reports, as a function of what has happened to it.
///
/// Kept apart from the machinery that causes the events so the rules can be
/// read, and tested, without a file, a decoder or a clock.
struct PlaybackStateMachine {
    /// Something that happened to the player.
    enum Event: Equatable {
        /// The file opened and its streams are known.
        case opened
        /// The first frame is ready to show, which is when a clip stops
        /// looking like it is still loading.
        case firstFrame
        /// Nothing left to show and the file has not ended: the network is
        /// behind.
        case starved
        /// Enough has arrived to carry on.
        case refilled
        case play
        case pause
        /// The last frame has been shown.
        case endOfStream
        case failed(String)
    }

    private(set) var state: PlaybackState = .idle
    /// Whether the clip starts by itself once there is something to show.
    var autoplays: Bool
    /// Whether the end of the clip is the end, or the way back to the start.
    ///
    /// A looping clip never reports that it finished: the app restarts it and
    /// the picture never stops, which is what a reader watching a
    /// three-second WebM expects.
    var isLooping: Bool

    init(autoplays: Bool = true, isLooping: Bool = false) {
        self.autoplays = autoplays
        self.isLooping = isLooping
    }

    @discardableResult
    mutating func handle(_ event: Event) -> PlaybackState {
        if case .failed(let message) = event {
            state = .failed(message)
            return state
        }

        // A failure stands until another file is opened. Everything else that
        // arrives afterwards is the machinery winding down and must not be
        // allowed to report that all is well.
        if case .failed = state, event != .opened {
            return state
        }

        switch event {
        case .opened:
            state = .preparing
        case .firstFrame:
            // Only from preparing: a first frame arriving again after a seek
            // must not restart a clip the reader has paused.
            if state == .preparing {
                state = autoplays ? .playing : .paused
            }
        case .starved:
            if state == .playing { state = .buffering }
        case .refilled:
            if state == .buffering { state = .playing }
        case .play:
            state = .playing
        case .pause:
            if state != .finished { state = .paused }
        case .endOfStream:
            state = isLooping ? .playing : .finished
        case .failed:
            break
        }
        return state
    }
}
