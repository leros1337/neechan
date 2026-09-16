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
