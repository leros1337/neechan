import NeechanAPI
import NeechanCore
import NeechanMedia
import SwiftUI

/// One page of the gallery: a still, an animation or a video.
struct GalleryPage: View {
    let item: GalleryItem
    let url: URL?
    let playerOptions: MediaPlayerOptions
    /// The gallery's player, shown by whichever video page is on screen.
    let player: MediaPlayer
    /// Only the page on screen loads its media, so paging does not start three
    /// decoders at once.
    let isCurrent: Bool
    var onSingleTap: () -> Void
    /// The long-press menu's actions, which belong to the gallery rather than
    /// to one page: saving and sharing are about the file on screen.
    var onGoToPost: (() -> Void)?
    var onSave: () -> Void = {}
    var onShare: () -> Void = {}
    /// Reports a picture being magnified, so the gallery leaves the
    /// drag-to-close gesture alone while the reader moves it about.
    var onZoomChanged: (Bool) -> Void = { _ in }
    /// Playback is reported upward so the gallery can host one control stack
    /// rather than each page drawing its own bar.
    @Binding var playbackState: PlaybackState
    @Binding var playbackProgress: PlaybackProgress
    @Binding var playbackControl: PlaybackControl

    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase

    @State private var loadState: PageLoadState = .idle
    /// Set once a stream has failed and the clip has been fetched whole
    /// instead, so one unplayable file cannot start that over and over.
    @State private var hasFallenBackToDownload = false

    private enum PageLoadState {
        case idle
        case loading
        case still(PlatformImage)
        case animated(AnimatedFrameDecoder, AnimatedImageDecoder.Metadata)
        /// A video, already on the device: the engine plays a local file.
        case video(URL)
        case failed(String)
    }

    var body: some View {
        Group {
            // Decided from what the item is, which is known before the page is
            // ever drawn, rather than from what has loaded so far. Deciding it
            // from the load state swapped the page's whole view tree the moment
            // a clip opened, which is in the middle of the swipe that brought
            // it on screen, and the pager stopped where it was: half a page of
            // video and half a page of the black neighbour beside it.
            if item.isVideo {
                // No long-press menu on a video, and not for want of one: the
                // controls under it already save and share.
                //
                // The reason is what the menu does to the view it is attached
                // to. For the press-and-hold animation, SwiftUI hosts a second
                // copy of that view, and a copy of this one is a copy of the
                // player: it opened the file, started its threads and began
                // playing, fifty milliseconds behind the one on screen, and
                // since the copy is thrown away rather than removed it was
                // never told to stop. Every video played twice over itself,
                // and the copies piled up as the reader swiped.
                surface
            } else {
                // The system's own press, with a preview of our own. Left to
                // itself it lifts the view the menu is attached to, and here
                // that is the whole screen: it spent a second or two rendering
                // a full-size copy of the picture and drew it over the menu
                // while it worked. A small card costs nothing to render.
                //
                // A long press of our own was tried instead and cost more than
                // it bought: written either way it left the pager unable to
                // turn to the next file once it had fired.
                surface.contextMenu {
                    menu
                } preview: {
                    menuPreview
                }
            }
        }
        .task(id: isCurrent) {
            guard isCurrent else { return }
            await load()
        }
        // Streaming asks the server for pieces of a file. Most oblige, and 2ch
        // does, but a host that will not would leave the reader watching a
        // picture that never starts. A failure falls back to fetching the whole
        // clip, which is what every video did until now.
        .onChange(of: playbackState) { _, state in
            guard case .failed = state, isCurrent, !hasFallenBackToDownload else { return }
            guard case .video(let playing) = loadState, !playing.isFileURL else { return }
            hasFallenBackToDownload = true
            Task { await fetchWholeFile() }
        }
    }

    /// The page itself, without the long-press menu.
    private var surface: some View {
        ZStack {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
    }

    /// What a long press offers.
    @ViewBuilder
    private var menu: some View {
        if let onGoToPost {
            Button(action: onGoToPost) {
                Label {
                    Text("Go to post", bundle: .module)
                } icon: {
                    Image(systemName: "text.bubble")
                }
            }
            // The number is in the identifier rather than on screen: the reader
            // is looking at the file and knows which post they opened it from.
            .accessibilityIdentifier("go-to-post-\(item.postNum)")
        }

        Button(action: onSave) {
            Label {
                Text("Save", bundle: .module)
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
        }

        Button(action: onShare) {
            Label {
                Text("Share", bundle: .module)
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }

        if let postURL {
            Section {
                LinkActionsMenu(url: postURL, title: "\u{2116}\(item.postNum)")
            }
        }
    }

    /// The card the menu lifts: small on purpose.
    @ViewBuilder
    private var menuPreview: some View {
        switch loadState {
        case .still(let image):
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
        default:
            // A clip has no still to show, and one being fetched has nothing
            // yet, so the file says what it is instead.
            VStack(spacing: 8) {
                Image(systemName: item.isVideo ? "film" : "photo")
                    .font(.largeTitle)
                Text(verbatim: "\u{2116}\(item.postNum)")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .frame(width: 200, height: 140)
        }
    }

    /// The post this file was attached to, on the site.
    private var postURL: URL? {
        SiteLinks.post(
            board: item.threadKey.board,
            threadNum: item.threadKey.threadNum,
            postNum: item.postNum,
            on: services.settings.siteSelection
        )
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView()
                .tint(.white)
                .onTapGesture(perform: onSingleTap)

        case .still(let image):
            #if os(iOS)
            ZoomableImageView(
                image: image,
                onSingleTap: onSingleTap,
                onZoomChanged: onZoomChanged
            )
            #else
            Image(platformImage: image).resizable().scaledToFit()
            #endif

        case .animated(let decoder, let metadata):
            #if os(iOS)
            // Paused unless this is the page being looked at and the app is in
            // front. A paged gallery keeps its neighbours alive, so without this
            // every animation the reader had swiped past went on drawing.
            AnimatedImageView(
                decoder: decoder,
                metadata: metadata,
                isPaused: !isCurrent || scenePhase != .active
            )
                .onTapGesture(perform: onSingleTap)
            #else
            EmptyView()
            #endif

        case .video(let file):
            // Only the page being looked at gets a player. A paging view keeps
            // the pages either side alive, and a player built for one of those
            // opens the file, starts its threads and begins fetching straight
            // away: three clips pulling at once over one connection, none of
            // them the one on screen. The head of the next is warmed by the
            // prefetcher instead, which is what that is for.
            if isCurrent {
                VideoPage(
                    player: player,
                    url: file,
                    options: playerOptions,
                    onSingleTap: onSingleTap,
                    state: $playbackState,
                    progress: $playbackProgress,
                    control: $playbackControl
                )
            } else {
                Color.black
                    .onTapGesture(perform: onSingleTap)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Could not load this file", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            }
            .foregroundStyle(.white)
            .onTapGesture(perform: onSingleTap)
        }
    }

    /// Fetches the whole clip and plays it from disk.
    ///
    /// The fallback when streaming it did not work.
    private func fetchWholeFile() async {
        guard let url else { return }
        loadState = .loading
        do {
            let file = try await LocalMediaFile.resolve(
                url,
                referer: item.endpoints(mirror: services.settings.domain).web,
                downloader: services.downloader
            )
            guard !Task.isCancelled else { return }
            loadState = .video(file)
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(error.readableSaveMessage)
        }
    }

    private func load() async {
        guard let url else {
            loadState = .failed(String(localized: "This file has no address.", bundle: .module, locale: AppLocale.current))
            return
        }
        loadState = .loading
        let referer = item.endpoints(mirror: services.settings.domain).web

        if item.isVideo {
            // Played from the site, not fetched first. The engine reads through
            // the app's own networking rather than its own HTTP client, which
            // Cloudflare refuses, so the picture starts on the first frames
            // instead of after the last byte. A clip already in the media cache
            // is played from disk, which is faster still and works offline.
            if let cached = await MediaCache.shared.cachedFile(for: url) {
                loadState = .video(cached)
            } else {
                loadState = .video(url)
            }
            return
        }
        do {
            // Fetched and decoded away from the main actor: the app's own
            // downloader rather than a fresh one, because building a
            // `Downloader` builds a `URLSession` and this runs on every page
            // the reader swipes to.
            let loaded = try await GalleryMediaLoader.load(
                url: url,
                referer: referer,
                fetcher: services.downloader
            )
            guard !Task.isCancelled else { return }
            switch loaded {
            case .still(let image):
                loadState = .still(image)
            case .animated(let decoder, let metadata):
                loadState = .animated(decoder, metadata)
            }
        } catch is GalleryMediaLoader.LoadError {
            guard !Task.isCancelled else { return }
            loadState = .failed(
                String(
                    localized: "This file is not an image.",
                    bundle: .module,
                    locale: AppLocale.current
                )
            )
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(String(describing: error))
        }
    }
}

/// A video surface. The transport lives in the gallery's control stack, so
/// this draws nothing but the picture and its loading and failure states.
private struct VideoPage: View {
    let player: MediaPlayer
    let url: URL
    let options: MediaPlayerOptions
    var onSingleTap: () -> Void
    /// The long-press menu's actions, which belong to the gallery rather than
    /// to one page: saving and sharing are about the file on screen.
    var onGoToPost: (() -> Void)?
    var onSave: () -> Void = {}
    var onShare: () -> Void = {}

    @Binding var state: PlaybackState
    @Binding var progress: PlaybackProgress
    @Binding var control: PlaybackControl

    var body: some View {
        ZStack {
            MediaPlayerView(
                player: player,
                url: url,
                options: options,
                state: $state,
                progress: $progress,
                control: $control,
                screen: "viewer"
            )
            .onTapGesture(perform: onSingleTap)

            if state.isBusy {
                ProgressView().tint(.white)
            }

            if case .failed(let message) = state {
                ContentUnavailableView {
                    Label {
                        Text("This video could not be played.", bundle: .module)
                    } icon: {
                        Image(systemName: "play.slash")
                    }
                } description: {
                    Text(message)
                }
                .foregroundStyle(.white)
            }
        }
    }
}
