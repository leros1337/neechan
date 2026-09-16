import NeechanAPI
import NeechanCore
import NeechanMedia
import SwiftUI

/// One page of the gallery: a still, an animation or a video.
struct GalleryPage: View {
    let item: GalleryItem
    let url: URL?
    let playerOptions: MediaPlayerOptions
    /// Only the page on screen loads its media, so paging does not start three
    /// decoders at once.
    let isCurrent: Bool
    var onSingleTap: () -> Void
    /// The long-press menu's actions, which belong to the gallery rather than
    /// to one page: saving and sharing are about the file on screen.
    var onGoToPost: (() -> Void)?
    var onSave: () -> Void = {}
    var onShare: () -> Void = {}
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
        ZStack {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .contextMenu { menu }
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
                LinkActionsMenu(url: postURL, title: "№\(item.postNum)")
            }
        }
    }

    /// The post this file was attached to, on the site.
    private var postURL: URL? {
        DvachLinks.post(
            board: item.threadKey.board,
            threadNum: item.threadKey.threadNum,
            postNum: item.postNum,
            on: services.settings.domain
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
            ZoomableImageView(image: image, onSingleTap: onSingleTap)
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
            VideoPage(
                url: file,
                options: playerOptions,
                onSingleTap: onSingleTap,
                state: $playbackState,
                progress: $playbackProgress,
                control: $playbackControl
            )

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
                referer: services.settings.domain.baseURL,
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
        let referer = services.settings.domain.baseURL

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
                url: url,
                options: options,
                state: $state,
                progress: $progress,
                control: $control
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
