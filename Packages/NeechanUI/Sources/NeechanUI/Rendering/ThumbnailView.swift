import NeechanAPI
import NeechanCore
import NeechanMedia
import SwiftUI

/// An attachment's thumbnail.
///
/// Resolves the server-relative path against the mirror currently selected, so
/// switching mirrors needs no stored data to change.
public struct ThumbnailView: View {
    let attachment: Attachment
    /// Fixed side length, or nil to fill whatever space the parent gives.
    let side: CGFloat?

    @Environment(AppServices.self) private var services
    @State private var image: PlatformImage?
    @State private var didFail = false
    /// Set when the reader taps a thumbnail the media policy is holding back.
    @State private var isForced = false
    /// Set when the reader taps through the safe-for-work blur.
    @State private var isRevealed = false

    public init(attachment: Attachment, side: CGFloat?) {
        self.attachment = attachment
        self.side = side
    }

    public var body: some View {
        sized
            .blur(radius: isBlurred ? 12 : 0)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: side == nil ? 0 : 10))
            .overlay { revealButton }
            .overlay(alignment: .bottomTrailing) { badge }
            // Names the format so a reader using VoiceOver, and the UI tests,
            // can tell a WebM from an MP4 without opening it.
            .accessibilityIdentifier("attachment-\(attachment.fileExtension)")
            .accessibilityLabel(accessibilityDescription)
            .task(id: attachment.thumbnail) { await load() }
            .task(id: isForced) { if isForced { await load() } }
    }

    /// Either a fixed square, or one that fills the width it is offered.
    @ViewBuilder
    private var sized: some View {
        if let side {
            // The reader's thumbnail scale applies to fixed sizes; a thumbnail
            // that fills its slot is already as large as the layout allows.
            let scaled = side * services.settings.thumbnailScale
            content.frame(width: scaled, height: scaled)
        } else {
            // A square that fits inside the space offered. Asking for
            // `contentMode: .fill` here grows the view past the proposal, which
            // is what made grid cells overlap their neighbours.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { content }
                .clipped()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
        } else if isHeldBack {
            // A held-back thumbnail is still a tap away, so the policy saves
            // data without hiding what a post contains.
            Button {
                isForced = true
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else if didFail {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            // A placeholder rather than nothing: an empty box behind glass reads
            // as a layout gap, not as an image on its way.
            Image(systemName: attachment.isVideo ? "film" : "photo")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    /// Covers a blurred thumbnail, so the first tap reveals it rather than
    /// opening whatever the reader cannot yet see.
    @ViewBuilder
    private var revealButton: some View {
        if isBlurred {
            Button {
                isRevealed = true
            } label: {
                Image(systemName: "eye")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Reveal", bundle: .module))
        }
    }

    /// Videos are marked so the reader knows a tap will play something.
    @ViewBuilder
    private var badge: some View {
        if attachment.isVideo {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                if let duration = attachment.durationText {
                    Text(duration)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: .capsule)
            .padding(3)
        } else if attachment.isAnimated {
            Text(verbatim: "GIF")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: .capsule)
                .padding(3)
        }
    }

    private var accessibilityDescription: Text {
        if attachment.isVideo {
            Text("Video, \(attachment.fileExtension)", bundle: .module)
        } else if attachment.isAnimated {
            Text("Animation, \(attachment.fileExtension)", bundle: .module)
        } else {
            Text("Image, \(attachment.fileExtension)", bundle: .module)
        }
    }

    /// True while the media policy is keeping this thumbnail off the network.
    private var isHeldBack: Bool {
        !services.allowsMediaLoading && !isForced
    }

    /// Thumbnails are blurred in safe-for-work mode until tapped.
    private var isBlurred: Bool {
        services.settings.safeForWork && !isRevealed && image != nil
    }

    private func load() async {
        guard services.allowsMediaLoading || isForced else { return }
        let domain = services.settings.domain
        guard let url = domain.url(forPath: attachment.thumbnail) else {
            didFail = true
            return
        }
        if let cached = await ImageLoader.shared.cachedImage(at: url) {
            image = cached
            return
        }
        do {
            image = try await ImageLoader.shared.image(at: url, referer: domain.baseURL)
            didFail = false
        } catch {
            didFail = !Task.isCancelled
        }
    }
}

extension Image {
    /// Bridges the platform image type the loader returns.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
