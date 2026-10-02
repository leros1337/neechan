import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Copy, share and open-in-browser for a 2ch address.
///
/// Gathered in one place so every screen offers the same three actions in the
/// same order, rather than each reinventing them.
struct LinkActionsMenu: View {
    let url: URL
    /// Shown as the share sheet's title.
    let title: String

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
            openInSafari(url)
        } label: {
            Label {
                Text("Open in browser", bundle: .module)
            } icon: {
                Image(systemName: "safari")
            }
        }
    }
}

/// Hands an address to the system browser.
///
/// Not the environment's `openURL`. A thread installs its own handler there,
/// which turns a 2ch address into navigation inside the app, and every screen
/// presented from the thread inherits it: "Open in browser" on a post opened
/// the post in the thread behind the viewer, where nobody could see it.
func openInSafari(_ url: URL) {
    #if canImport(UIKit)
    UIApplication.shared.open(url)
    #elseif canImport(AppKit)
    NSWorkspace.shared.open(url)
    #endif
}

/// Puts text on the clipboard, where there is one.
func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
}
