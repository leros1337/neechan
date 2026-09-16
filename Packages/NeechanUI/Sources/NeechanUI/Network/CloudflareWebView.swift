import NeechanAPI
import NeechanCore
import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

#if canImport(WebKit) && os(iOS)
/// Shows the site's own browser check, then hands its cookies back to the app.
///
/// Cloudflare hands out `cf_clearance` only to a real browser engine. The web
/// view must present the same user agent as the app's session, or the cookie it
/// earns will not be accepted on the app's own requests.
struct CloudflareWebView: UIViewRepresentable {
    let url: URL
    /// Called with the cookies the check produced, once it has passed.
    let onPassed: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPassed: onPassed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Normally this is the agent the web view would have used anyway, since
        // that is where the app's came from. Set explicitly so the two still
        // agree in the case that matters: when the read failed and everything
        // else is on the fallback.
        webView.customUserAgent = UserAgent.current
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onPassed: ([HTTPCookie]) -> Void

        init(onPassed: @escaping ([HTTPCookie]) -> Void) {
            self.onPassed = onPassed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The challenge page reloads itself once it passes, so the cookies
            // are read after every load rather than only the first.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [onPassed] cookies in
                let relevant = cookies.filter { $0.domain.contains("2ch") }
                guard relevant.contains(where: { $0.name == "cf_clearance" }) else { return }
                onPassed(relevant)
            }
        }
    }
}

/// The sheet the app puts the check in, with a way out that is not the check.
struct CloudflareChallengeSheet: View {
    let url: URL

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CloudflareWebView(url: url) { cookies in
                Task {
                    await services.cookies.adopt(cookies)
                    dismiss()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(Text("Browser check", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                }
            }
        }
    }
}
#else
/// On platforms without WebKit the check cannot be shown; the sheet says so
/// rather than presenting an empty rectangle.
struct CloudflareChallengeSheet: View {
    let url: URL

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Browser check", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.shield")
            }
        } description: {
            Text("Open the site in a browser to pass the check.", bundle: .module)
        }
    }
}
#endif
