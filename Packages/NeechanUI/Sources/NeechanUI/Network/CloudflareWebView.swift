import NeechanAPI
import os
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
    /// Whose check this is, so only that site's cookies are taken from it.
    let site: Imageboard
    /// Called with the cookies the check produced, once it has passed.
    let onPassed: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(site: site, onPassed: onPassed)
    }

    static let log = Logger(subsystem: Signposts.subsystem, category: "browser-check")

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
        Self.log.notice("check opened for \(url.absoluteString, privacy: .public)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onPassed: ([HTTPCookie]) -> Void

        let site: Imageboard

        /// The gate cookies the *app* already held when this opened.
        ///
        /// Taken from the app's own jar rather than from the web view's first
        /// load, and taken before anything loads. A gate's script runs while
        /// the page is loading, so by the time `didFinish` arrives its cookie is
        /// already set: treating that as the baseline marked the very thing the
        /// reader had just earned as pre-existing, and the check sat there
        /// having already succeeded.
        ///
        /// The app's jar is also the right question to ask. What matters is not
        /// what the web view has, but whether it has something the client does
        /// not.
        private let knownGateCookies: [String: String]

        init(site: Imageboard, onPassed: @escaping ([HTTPCookie]) -> Void) {
            self.site = site
            self.onPassed = onPassed
            let names = site.gateCookieNames
            knownGateCookies = site.cookieHosts
                .flatMap { HTTPCookieStorage.shared.cookies(for: $0) ?? [] }
                .filter { names.contains($0.name) }
                .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
            CloudflareWebView.log.notice(
                "check baseline: \(self.knownGateCookies.keys.sorted().joined(separator: ","), privacy: .public)"
            )
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            CloudflareWebView.log.error("check load failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // What the page actually is, before deciding anything from its
            // cookies. A gate script sets its cookie *while loading*, so the
            // cookie being present says only that the script ran — not that
            // the reload it triggers got through. Passing means the page that
            // finished is no longer the gate.
            webView.evaluateJavaScript("document.documentElement.outerHTML.slice(0, 400)") { [weak self] html, _ in
                let page = (html as? String) ?? ""
                let isStillGate = page.contains("_tcs=") || page.contains("challenge-platform")
                CloudflareWebView.log.notice(
                    "check page \(isStillGate ? "is still the gate" : "is content", privacy: .public): \(page.prefix(160), privacy: .public)"
                )
                guard !isStillGate else { return }
                self?.collectCookies(from: webView)
            }
        }

        private func collectCookies(from webView: WKWebView) {
            // A challenge page reloads itself once it passes, so the cookies are
            // read after every load rather than only the first.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                // Substrings rather than host equality: cookie domains come
                // back with a leading dot, and one token covers a site's
                // several hosts. A site's jar is its own — nothing here mixes
                // two of them.
                let tokens = site.cookieMatchTokens
                let relevant = cookies.filter { cookie in
                    tokens.contains { cookie.domain.contains($0) }
                }
                let names = site.gateCookieNames
                let gate = relevant
                    .filter { names.contains($0.name) }
                    .reduce(into: [String: String]()) { $0[$1.name] = $1.value }

                // Any gate cookie the app does not already hold means the page
                // did the work it was opened for. 4chan's script writes `_tcs`
                // while loading, so this can be true on the very first finish.
                let isNew = gate.contains { knownGateCookies[$0.key] != $0.value }
                CloudflareWebView.log.notice(
                    """
                    check finished \(webView.url?.absoluteString ?? "?", privacy: .public) \
                    site cookies: \(relevant.map(\.name).sorted().joined(separator: ","), privacy: .public) \
                    gate: \(gate.keys.sorted().joined(separator: ","), privacy: .public) \
                    new: \(isNew, privacy: .public)
                    """
                )
                guard isNew else { return }
                onPassed(relevant)
            }
        }
    }
}

/// The screen the app puts the check in, with a way out that is not the check.
///
/// Closed by clearing the pending check rather than by `dismiss`: this is
/// hosted in a window of its own (see `ChallengeWindow`), and there is no
/// presentation for `dismiss` to end — it would leave the reader holding a web
/// view with an inert Cancel button.
struct CloudflareChallengeSheet: View {
    let url: URL

    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationStack {
            // The request that was refused, and not some friendlier page: the
            // interstitial is served *by that request*, and running it is the
            // whole point. It writes its cookie and reloads, and the reload
            // renders as a blank page because the answer underneath is JSON —
            // which is why this closes itself the moment the cookie appears
            // rather than leaving the reader looking at it.
            CloudflareWebView(url: url, site: services.site) { cookies in
                Task {
                    await services.adoptChallengeCookies(cookies)
                    services.clearPendingChallenge()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(Text("Browser check", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        services.clearPendingChallenge()
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
