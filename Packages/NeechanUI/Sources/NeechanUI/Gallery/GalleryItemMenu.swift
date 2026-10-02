import NeechanAPI
import NeechanCore
import SwiftUI

/// What a long press on a file offers, in the viewer and in the grid alike.
///
/// One view so the two places cannot drift apart: a reader who learns the menu
/// in one expects the same actions, in the same order, in the other.
struct GalleryItemMenu: View {
    let item: GalleryItem
    var onGoToPost: (() -> Void)?
    var onSave: () -> Void
    var onShare: () -> Void

    @Environment(AppServices.self) private var services

    var body: some View {
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

        // The file's own address, not the post's: a link copied from a video
        // is wanted for the video. The post is "Go to post" away.
        if let fileURL = item.fileURL(mirror: services.settings.domain) {
            Section {
                LinkActionsMenu(url: fileURL, title: shareTitle)
            }
        }
    }

    /// The file's name as it was posted, or the post's number when it has none.
    private var shareTitle: String {
        let name = item.attachment.displayName
        return name.isEmpty ? "\u{2116}\(item.postNum)" : name
    }
}

/// The card a long press lifts when there is no picture to show: what the file
/// is, and which post it came from.
///
/// Small on purpose. Left to itself the menu lifts a copy of the view it hangs
/// on, which over a file is the whole screen, and rendering that took a second
/// or two and drew over the menu while it did.
struct GalleryItemMenuCard: View {
    let item: GalleryItem

    var body: some View {
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
