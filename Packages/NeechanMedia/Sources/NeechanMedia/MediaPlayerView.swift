import SwiftUI

/// Plays a video.
///
/// Video is decoded by FFmpeg whatever the container: AVFoundation cannot open
/// VP8 or VP9 at all, and refuses the `hev1`-tagged HEVC the boards serve in
/// MP4. Callers see only this view and `PlaybackState`.
public struct MediaPlayerView: View {
    private let url: URL
    private let options: MediaPlayerOptions
    /// Where this view was written, for telling two of them apart in a log.
    private let origin: String

    @Binding private var state: PlaybackState
    @Binding private var progress: PlaybackProgress
    @Binding private var control: PlaybackControl

    /// A player lent by the caller, which then owns its lifetime.
    ///
    /// The alternative, a player of the view's own, lives and dies with the
    /// view, and a paged gallery is not reliable about either: it builds two
    /// views for the page it lands on and never tells the spare one it has
    /// gone. Every clip swiped past then kept playing, unseen, to its end. A
    /// player owned by the screen's model stops when the model says so.
    private let lentPlayer: MediaPlayer?
    @State private var ownedPlayer = OwnedPlayer()
    private var player: MediaPlayer { lentPlayer ?? ownedPlayer.player }

    /// Made only if the view is not lent one, and then kept for its life.
    @MainActor private final class OwnedPlayer {
        lazy var player = MediaPlayer()
    }
    /// Kept so the view can be laid out again when a clip that is turned on
    /// its side replaces one that is not.
    @State private var rotationDegrees: Double = 0

    /// - Parameters:
    ///   - screen: what this player is for, in a word, for the log. Two
    ///     players running at once means two views each asked for one, and
    ///     without this a log says only that it happened, not where.
    public init(
        url: URL,
        options: MediaPlayerOptions,
        state: Binding<PlaybackState>,
        progress: Binding<PlaybackProgress>,
        control: Binding<PlaybackControl>,
        screen: String = #fileID,
        line: Int = #line
    ) {
        self.init(
            player: nil, url: url, options: options, state: state, progress: progress,
            control: control, screen: screen, line: line
        )
    }

    /// The same, showing a player the caller owns.
    ///
    /// The caller loads nothing: this view loads `url` into the player when
    /// it appears and when the URL changes, as it does with a player of its
    /// own. What the caller does is decide when the player stops, by calling
    /// `shutdown()` on it; this view will not, since a second view for the
    /// same page may still be showing it.
    public init(
        player: MediaPlayer?,
        url: URL,
        options: MediaPlayerOptions,
        state: Binding<PlaybackState>,
        progress: Binding<PlaybackProgress>,
        control: Binding<PlaybackControl>,
        screen: String = #fileID,
        line: Int = #line
    ) {
        lentPlayer = player
        origin = "\((screen as NSString).lastPathComponent):\(line)"
        self.url = url
        self.options = options
        _state = state
        _progress = progress
        _control = control
    }

    public var body: some View {
        PlayerLayerView(displayLayer: player.displayLayer, rotationDegrees: rotationDegrees)
            .onAppear {
                player.onState = { newState in
                    state = newState
                    rotationDegrees = player.rotationDegrees
                }
                player.onProgress = { progress = $0 }
                player.describe(as: origin)
                player.load(url: url, options: options)
            }
            // A feed keeps one player and changes the clip under it, which is
            // deliberately not a new view: the layer, the clock and the mute
            // setting all carry over.
            .onChange(of: url) { _, newURL in
                player.load(url: newURL, options: options)
            }
            .onChange(of: control) { _, newControl in
                apply(newControl)
            }
            .onDisappear {
                // A lent player is the lender's to stop.
                if lentPlayer == nil { player.shutdown() }
            }
    }

    private func apply(_ control: PlaybackControl) {
        switch control.command {
        case .none:
            break
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .seek(let time):
            player.seek(to: time)
        case .setMuted(let muted):
            player.isMuted = muted
        case .setLooping(let looping):
            player.setLooping(looping)
        }
    }
}
