import NeechanCore
import SwiftUI

/// The reader's favorites, over the screen that asked for them.
///
/// A thread opens this rather than sending the reader to the Favorites tab,
/// which would mean leaving the thread to go and look. Choosing something here
/// does take them there properly: the window closes and the thread or board
/// opens on the stack they were already in, so Back returns to the thread they
/// were reading.
struct FavoritesWindow: View {
    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    /// A web link opened from inside the window.
    ///
    /// Its own, rather than the host screen's: that screen is busy presenting
    /// this window, so a browser it tried to present would have nowhere to go
    /// and nothing would appear.
    @State private var browserLink: BrowserLink?

    var body: some View {
        NavigationStack {
            FavoritesView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Label {
                                Text("Done", bundle: .module)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
        }
        // The tab bar is mirrored so its pill falls under the thumb, and each
        // tab's stack sets the direction back; a window belongs to no tab and
        // has to do it for itself.
        .environment(\.layoutDirection, .leftToRight)
        .internalBrowser(link: $browserLink)
        // A presented view does not usefully inherit this: without its own
        // handler, a link tapped in here would be given to the screen
        // underneath, which cannot show anything while this window is up.
        .environment(\.openURL, OpenURLAction { url in
            guard case .external(let target) = NeechanURL.action(for: url) else {
                // A `>>` means nothing outside the thread it was written in.
                return .handled
            }
            guard services.settings.usesInternalBrowser else { return .systemAction }
            browserLink = BrowserLink(url: target)
            return .handled
        })
        .onAppear { router.openWindow() }
        // A row pushes through the router, which closes the window as it hands
        // the reader over. That is the signal to get out of the way.
        .onChange(of: router.isWindowOpen) { _, isOpen in
            if !isOpen { dismiss() }
        }
        // On the window rather than on its button, so swiping it away and
        // tapping Done leave the router in the same state.
        .onDisappear { router.closeWindow() }
    }
}
