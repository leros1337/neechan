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

        if let postURL {
            Section {
                LinkActionsMenu(url: postURL, title: "\u{2116}\(item.postNum)")
            }
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
}
