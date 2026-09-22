import NeechanAPI
import os
import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

#if canImport(WebKit) && os(iOS)
/// The site's own report page, for a site that has no report API.
///
/// 4chan's form is an ordinary HTML page on the posting host, and that host is
/// behind the gate that already refuses this app's posts. A browser engine
/// passes it where a `URLRequest` does not, so the reader fills in the real
/// form, with the site's own reason list and its own T-Captcha, and nothing
/// here has to reimplement either.
///
/// Deliberately not `SFSafariViewController`, which the internal-browser
/// preference uses: that brings an address bar and will navigate anywhere,
/// which would make a report button into a way into the whole site. This goes
/// to one page and stays there.
struct ReportWebView: UIViewRepresentable {
    let url: URL
    /// Called when the page says the report went through.
    let onReported: () -> Void

    static let log = Logger(subsystem: Signposts.subsystem, category: "report")

    /// The page ends by telling the window that opened it, then closing itself:
    ///
    /// ```js
    /// window.opener.postMessage('done-report', '*');
    /// self.close();
    /// ```
    ///
    /// There is no opener here, so both would throw and the reader would be
    /// left looking at a form that had already worked. This supplies the one
    /// the page expects and routes each into the handler below.
    private static let openerShim = """
        window.opener = { postMessage: function (message) {
            window.webkit.messageHandlers.report.postMessage(String(message));
        } };
        window.close = function () {
            window.webkit.messageHandlers.report.postMessage('closed');
        };
        """

    func makeCoordinator() -> Coordinator {
        Coordinator(host: url.host(), onReported: onReported)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: Self.openerShim,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        controller.add(context.coordinator, name: "report")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // The shared store, so a gate cookie already earned is one the reader
        // does not earn again.
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // The same agent the app's own requests send, for the same reason the
        // browser check sets it: the two have to agree or the cookie this page
        // earns is refused afterwards.
        webView.customUserAgent = UserAgent.current
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // The content controller holds the coordinator strongly, and the web
        // view holds the controller. Without this the pair outlives the sheet.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "report")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// The host the form is on. Anything else is somewhere this sheet does
        /// not go.
        private let host: String?
        private let onReported: () -> Void

        init(host: String?, onReported: @escaping () -> Void) {
            self.host = host
            self.onReported = onReported
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String else { return }
            ReportWebView.log.notice("report page said \(body, privacy: .public)")
            // `closed` arrives too, right after, and is ignored: the page closes
            // itself whether or not the report was accepted, so it says nothing
            // about the outcome.
            guard body.contains("done-report") else { return }
            onReported()
        }

        /// Keeps the sheet on the host it was opened for.
        ///
        /// The form links out to the site's rules, and a tap on one inside a
        /// report sheet would leave the reader browsing 4chan in a window with
        /// no address bar and no way back.
        ///
        /// Every navigation is judged, main frame or not: a subresource — the
        /// stylesheet, the captcha script — is not a navigation and never
        /// reaches here, so the page still loads everything it needs. A URL
        /// with no host at all is the form posting back to itself.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let destination = navigationAction.request.url?.host()
            guard destination == nil || destination == host else {
                ReportWebView.log.notice(
                    "refused navigation to \(destination ?? "?", privacy: .public)"
                )
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// The report page in a sheet, with a way out that is not succeeding at it.
struct ReportWebSheet: View {
    let url: URL
    let onReported: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReportWebView(url: url) {
                onReported()
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(Text("Report post", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label {
                            Text("Close", bundle: .module)
                        } icon: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
        }
    }
}
#endif
