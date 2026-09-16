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
    @State private var loadState: PageLoadState = .idle

    private enum PageLoadState {
        case idle
        case loading
        case still(PlatformImage)
        case animated(AnimatedImageDecoder.Animation)
        case video
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

        case .animated(let animation):
            #if os(iOS)
            AnimatedImageView(animation: animation)
                .onTapGesture(perform: onSingleTap)
            #else
            EmptyView()
            #endif

        case .video:
            if let url {
                VideoPage(
                    url: url,
                    options: playerOptions,
                    onSingleTap: onSingleTap,
                    state: $playbackState,
                    progress: $playbackProgress,
                    control: $playbackControl
                )
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

    private func load() async {
        guard let url else {
            loadState = .failed(String(localized: "This file has no address.", bundle: .module, locale: AppLocale.current))
            return
        }
        if item.isVideo {
            loadState = .video
            return
        }

        loadState = .loading
        let referer = services.settings.domain.baseURL
        do {
            // Full-size files are too large for URLCache to keep, so the gallery
            // uses its own disk cache: paging back to an image is instant and
            // costs no data.
            let data: Data
            if let cached = await MediaCache.shared.cachedFile(for: url),
               let bytes = try? Data(contentsOf: cached) {
                data = bytes
            } else {
                data = try await Downloader().data(url, referer: referer)
                try? await MediaCache.shared.store(data, for: url)
            }
            // An animated PNG or WebP is only detectable from its bytes, so the
            // decision is made here rather than from the file name.
            if AnimatedImageDecoder.isAnimated(data) {
                loadState = .animated(try AnimatedImageDecoder.decode(data))
            } else if let image = PlatformImage(data: data) {
                loadState = .still(image)
            } else {
                loadState = .failed(
                    String(localized: "This file is not an image.", bundle: .module, locale: AppLocale.current)
                )
            }
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
