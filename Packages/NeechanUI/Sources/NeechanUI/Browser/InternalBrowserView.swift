import NeechanSettings
import SwiftUI
#if canImport(SafariServices) && os(iOS)
import SafariServices
#endif

#if canImport(SafariServices) && os(iOS)
/// Opens a link inside the app.
///
/// `SFSafariViewController` rather than a bare web view: it brings Reader,
/// sharing and the address bar, and it keeps the reader in the app, which is
/// the point of the preference.
struct InternalBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

/// A link the app is showing in its own browser.
struct BrowserLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Opens a page off the imageboard the way the reader asked for.
///
/// In the app's own browser, so a tap does not lose what they were reading --
/// unless they asked for Safari, or have not yet said they are 18, in which
/// case the page opens in Safari rather than on a surface this app answers for.
@MainActor
func openOffSite(_ url: URL, settings: AppSettings, in browserLink: Binding<BrowserLink?>) {
    if settings.opensLinksInApp {
        browserLink.wrappedValue = BrowserLink(url: url)
    } else {
        openInSafari(url)
    }
}

extension View {
    /// Presents `link` in the internal browser, where there is one.
    @ViewBuilder
    func internalBrowser(link: Binding<BrowserLink?>) -> some View {
        #if canImport(SafariServices) && os(iOS)
        sheet(item: link) { link in
            InternalBrowserView(url: link.url)
                .ignoresSafeArea()
        }
        #else
        self
        #endif
    }
}
