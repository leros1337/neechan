import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Copy, share and open-in-browser for a 2ch address.
///
/// Gathered in one place so every screen offers the same three actions in the
/// same order, rather than each reinventing them.
struct LinkActionsMenu: View {
    let url: URL
    /// Shown as the share sheet's title.
    let title: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            copyToPasteboard(url.absoluteString)
        } label: {
            Label {
                Text("Copy link", bundle: .module)
            } icon: {
                Image(systemName: "link")
            }
        }

        ShareLink(item: url, subject: Text(title), message: Text(verbatim: "")) {
            Label {
                Text("Share link", bundle: .module)
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }

        Button {
            openURL(url)
        } label: {
            Label {
                Text("Open in browser", bundle: .module)
            } icon: {
                Image(systemName: "safari")
            }
        }
    }
}

/// Puts text on the clipboard, where there is one.
func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
}
