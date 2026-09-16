@preconcurrency import KSPlayer
import SwiftUI

/// Plays a video.
///
/// The engine underneath is chosen from `options.kind`: WebM goes to FFmpeg,
/// MP4 to AVFoundation. Callers see only this view and `PlaybackState`.
public struct MediaPlayerView: View {
    private let url: URL
    private let options: MediaPlayerOptions

    @Binding private var state: PlaybackState
    @Binding private var progress: PlaybackProgress
    @Binding private var control: PlaybackControl

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    /// Whether the clip restarts when it ends.
    ///
    /// Kept here as well as on the engine's options: the engine's own loop flag
    /// is read when a clip is opened, so turning looping on part-way through
    /// one did nothing. This restarts it by hand when it reaches the end.
    @State private var isLooping = false

    public init(
        url: URL,
        options: MediaPlayerOptions,
        state: Binding<PlaybackState>,
        progress: Binding<PlaybackProgress>,
        control: Binding<PlaybackControl>
    ) {
        self.url = url
        self.options = options
        _state = state
        _progress = progress
        _control = control
    }

    public var body: some View {
        KSVideoPlayer(
            coordinator: coordinator,
            url: url,
            options: KSPlayerBridge.makeOptions(from: options)
        )
        .onStateChanged { _, newState in
            let mapped = KSPlayerBridge.playbackState(from: newState)
            state = mapped
            if LoopPolicy.shouldRestart(state: mapped, isLooping: isLooping) {
                restart()
            }
        }
        .onPlay { current, total in
            progress = PlaybackProgress(current: current, total: total)
        }
        .onAppear {
            coordinator.isMuted = options.startsMuted
            isLooping = options.loops
        }
        .onChange(of: control) { _, newControl in
            apply(newControl)
        }
        .onDisappear {
            // The engine holds decoder threads and a Metal layer; a gallery that
            // pages through clips must let each one go.
            coordinator.playerLayer?.pause()
            coordinator.resetPlayer()
        }
    }

    private func apply(_ control: PlaybackControl) {
        switch control.command {
        case .none:
            break
        case .play:
            coordinator.playerLayer?.play()
        case .pause:
            coordinator.playerLayer?.pause()
        case .seek(let time):
            coordinator.seek(time: time)
        case .setMuted(let muted):
            coordinator.isMuted = muted
        case .setLooping(let looping):
            // Only the app's own flag is set: telling the engine would stop it
            // reporting the end of the clip, which is what the restart hangs on.
            isLooping = looping
            // Turning looping on after the clip already ended should start it
            // again rather than wait for an end that has been and gone.
            if LoopPolicy.shouldRestart(state: state, isLooping: looping) {
                restart()
            }
        }
    }

    /// Plays the clip again from the beginning.
    ///
    /// `play()` is all it takes: the layer rewinds by itself when it is asked to
    /// play something that has reached its end. Seeking first got in the way of
    /// that, because the seek is asynchronous and the play landed before it.
    ///
    /// Hopped to the next turn of the main actor because the layer is still
    /// inside its own end-of-playback work when it tells us the clip finished,
    /// and it stops its timer just after.
    private func restart() {
        Task { @MainActor in
            coordinator.playerLayer?.play()
        }
    }
}

/// A one-shot instruction to the player.
///
/// Carried as a value with a generation counter so that repeating the same
/// command (pause, pause) still takes effect.
public struct PlaybackControl: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        case none
        case play
        case pause
        case seek(TimeInterval)
        case setMuted(Bool)
        case setLooping(Bool)
    }

    public private(set) var command: Command
    private var generation: Int

    public init() {
        command = .none
        generation = 0
    }

    public mutating func send(_ command: Command) {
        self.command = command
        generation += 1
    }
}
