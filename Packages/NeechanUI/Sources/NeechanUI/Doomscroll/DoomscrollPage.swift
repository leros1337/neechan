import NeechanAPI
import NeechanCore
import NeechanMedia
import SwiftUI

/// One clip's worth of the feed.
///
/// Draws no video. The whole mode has one player, behind the scroll view, and
/// this is the hole the reader looks through: transparent once the scroll has
/// settled on it, and covered by the clip's own thumbnail at every other
/// moment, so a drag has something that moves with the finger.
struct DoomscrollPage: View {
    let item: GalleryItem
    /// True when this is the clip the player is on and nothing is moving.
    let isShowingVideo: Bool
    var onTap: () -> Void

    var body: some View {
        ZStack {
            // Both the backdrop and the poster go, together: the player is
            // *behind* this cell, so anything opaque left here hides the very
            // clip the cell is for. The neighbouring cells keep theirs, which
            // is what stops the one player showing through them during a drag.
            Color.black
            poster
        }
        .opacity(isShowingVideo ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isShowingVideo)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The video shows through, and taps still land here rather than on the
        // player, whose own gesture recognisers would otherwise eat them.
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .accessibilityIdentifier("doomscroll-page-\(item.postNum)")
    }

    /// The thumbnail, letterboxed the way the video will be.
    ///
    /// `ThumbnailView` cannot be used: it crops to a square, which would make
    /// the handover to the video a visible jump.
    @ViewBuilder
    private var poster: some View {
        if !item.attachment.thumbnail.isEmpty {
            RemotePoster(path: item.attachment.thumbnail)
        }
    }
}

/// A thumbnail loaded for the feed's backdrop.
private struct RemotePoster: View {
    @Environment(AppServices.self) private var services

    let path: String

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) {
            let endpoints = SiteEndpoints(services.settings.siteSelection)
            guard let url = endpoints.url(forPath: path) else { return }
            if let cached = await ImageLoader.shared.cachedImage(at: url, maxPixelSize: 900) {
                image = cached
                return
            }
            image = try? await ImageLoader.shared.image(
                at: url, referer: endpoints.web, maxPixelSize: 900
            )
        }
    }
}
