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
    /// How many attachments the post this thumbnail stands for carries.
    ///
    /// More than one and the thumbnail is a stack rather than a picture, and
    /// says so. One by default, so a thumbnail that stands only for itself —
    /// the gallery grid, the doomscroll feed — needs to say nothing.
    let attachmentCount: Int

    @Environment(AppServices.self) private var services
    @Environment(\.displayScale) private var displayScale
    @State private var image: PlatformImage?
    @State private var didFail = false
    /// Set when the reader taps a thumbnail the media policy is holding back.
    @State private var isForced = false
    /// Set when the reader taps through the safe-for-work blur.
    @State private var isRevealed = false

    public init(attachment: Attachment, side: CGFloat?, attachmentCount: Int = 1) {
        self.attachment = attachment
        self.side = side
        self.attachmentCount = attachmentCount
    }

    public var body: some View {
        sized
            // Applied only when it is wanted. A `.blur` installed at radius zero
            // is still a filter pass per thumbnail, and a board grid draws
            // dozens of them.
            .modifier(SafeForWorkBlur(isActive: isBlurred))
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: side == nil ? 0 : 10))
            .overlay { playIndicator }
            .overlay { revealButton }
            .overlay(alignment: .bottomTrailing) { badge }
            .overlay(alignment: .topTrailing) { countBadge }
            // Names the format so a reader using VoiceOver, and the UI tests,
            // can tell a WebM from an MP4 without opening it.
            .accessibilityIdentifier(
                attachmentCount > 1
                    ? "attachment-stack-\(attachmentCount)"
                    : "attachment-\(attachment.fileExtension)"
            )
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

    /// Marks a video, so a reader knows a tap plays something rather than
    /// opening a picture.
    ///
    /// Deliberately not a button. The whole thumbnail is already one tap target
    /// inside a `Button`, and a control in the middle of it would take the tap
    /// meant for the thumbnail and add a second element for VoiceOver to stop
    /// on. `PinBadge` on the board cells is the same idea.
    @ViewBuilder
    private var playIndicator: some View {
        if showsPlayIndicator {
            Image(systemName: "play.fill")
                .font(.system(size: playIndicatorSide * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: playIndicatorSide, height: playIndicatorSide)
                .glassEffect(in: .circle)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Whether there is a video, and a thumbnail under it to mark.
    ///
    /// `isBlurred` already means the image has loaded, so this reads as: a
    /// video, whose thumbnail has arrived, that safe-for-work mode is not
    /// covering. While it is still loading, or the media policy is holding it
    /// back, there is nothing for the button to sit on; and behind the blur the
    /// middle belongs to the reveal button.
    private var showsPlayIndicator: Bool {
        attachment.isVideo && image != nil && !isBlurred
    }

    /// How big the play button is, in points.
    ///
    /// Proportional, with a ceiling and no floor. A fixed size cannot serve this
    /// view: the compact board row asks for 44 points, where anything with a
    /// floor of twenty-odd would cover half the picture, and the same circle
    /// disappears on a grid cell that fills the width of the screen.
    private var playIndicatorSide: CGFloat {
        // A thumbnail that fills its cell has no side to scale from.
        guard let side else { return 40 }
        return min(40, side * services.settings.thumbnailScale * 0.34)
    }

    /// An animation is marked, because nothing else says that it moves.
    ///
    /// A video is not marked here: it carries a play button in the middle
    /// instead. The two want different things said about them — a video waits
    /// for a tap, while an animation is already running — so a shared badge that
    /// only differed by its text was saying the wrong thing about one of them.
    @ViewBuilder
    private var badge: some View {
        if attachment.isAnimated {
            Text(verbatim: "GIF")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: .capsule)
                .padding(3)
        }
    }

    /// Marks a thumbnail that stands for several attachments.
    ///
    /// Deliberately not a button, for the same reason `playIndicator` is not:
    /// the whole thumbnail is already one tap target, and a control inside it
    /// would take the tap meant for the stack and give VoiceOver a second
    /// element to stop on. The count goes into `accessibilityDescription`
    /// instead.
    ///
    /// Dashed rather than solid so it reads as "there is more behind this"
    /// rather than as a count of something that happened, which is what a
    /// solid badge says everywhere else in iOS.
    @ViewBuilder
    private var countBadge: some View {
        if attachmentCount > 1 {
            Text(attachmentCount, format: .number)
                .font(.system(size: countBadgeSide * 0.44, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: countBadgeSide, height: countBadgeSide)
                .glassEffect(in: .circle)
                .overlay {
                    Circle()
                        .strokeBorder(
                            .white.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                        )
                }
                .padding(4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Sized off the thumbnail the way the play button is, and a little smaller
    /// than it: a 44-point board row cannot carry two full-size marks.
    private var countBadgeSide: CGFloat {
        guard let side else { return 30 }
        return min(30, max(16, side * services.settings.thumbnailScale * 0.3))
    }

    /// One element rather than two: the badge is hidden from VoiceOver and its
    /// count is said here instead, so a stack is one stop, not a picture
    /// followed by a bare number.
    ///
    /// Written out per kind rather than assembled from a suffix, because the
    /// languages this ships in do not all put the count in the same place.
    private var accessibilityDescription: Text {
        if attachmentCount > 1 {
            if attachment.isVideo {
                Text("Video, \(attachment.fileExtension), 1 of \(attachmentCount)", bundle: .module)
            } else if attachment.isAnimated {
                Text("Animation, \(attachment.fileExtension), 1 of \(attachmentCount)", bundle: .module)
            } else {
                Text("Image, \(attachment.fileExtension), 1 of \(attachmentCount)", bundle: .module)
            }
        } else if attachment.isVideo {
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

    /// Thumbnails are blurred until tapped unless the reader asked for NSFW
    /// material as it comes.
    private var isBlurred: Bool {
        !services.settings.nsfwMode && !isRevealed && image != nil
    }

    /// The longest side this thumbnail will actually be drawn at, in pixels.
    ///
    /// Asking the decoder for this rather than the file's own size keeps the
    /// pixels off the render thread: an image decoded at draw time is decoded
    /// during the scroll. A tile that fills its slot has no fixed side, so it is
    /// given a sensible ceiling instead of the full file.
    private var targetPixelSize: Int {
        let points = (side ?? 320) * services.settings.thumbnailScale
        return Int((points * displayScale).rounded())
    }

    private func load() async {
        guard services.allowsMediaLoading || isForced else { return }
        // The site's own hosts. A thumbnail is served to anyone, but it is
        // asked for the same way as the full file so the two cannot drift.
        let endpoints = SiteEndpoints(services.settings.siteSelection)
        guard let url = endpoints.url(forPath: attachment.thumbnail) else {
            didFail = true
            return
        }
        let pixels = targetPixelSize
        if let cached = await ImageLoader.shared.cachedImage(at: url, maxPixelSize: pixels) {
            image = cached
            return
        }
        do {
            image = try await ImageLoader.shared.image(
                at: url, referer: endpoints.web, maxPixelSize: pixels
            )
            didFail = false
        } catch {
            didFail = !Task.isCancelled
        }
    }
}

/// The safe-for-work blur, mounted only while it is on.
private struct SafeForWorkBlur: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.blur(radius: 12)
        } else {
            content
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
