import NeechanAPI
import os
import SwiftUI
#if canImport(WebKit) && os(iOS)
import WebKit

/// The further check 4chan sometimes asks for before it hands out a captcha.
///
/// It is hCaptcha's widget, which exists only as a web page, so this is the
/// one part of 4chan's captcha that is not drawn natively. The page carries the
/// board's address, as the site's own does, and the widget's token goes back
/// to the site with the next request for a captcha. The reader answers it; the
/// app only passes the token on.
struct TicketCaptchaSheet: View {
    let siteKey: String
    let board: String
    let onToken: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TicketCaptchaWebView(siteKey: siteKey, board: board, onToken: onToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("Check", bundle: .module))
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

private struct TicketCaptchaWebView: UIViewRepresentable {
    let siteKey: String
    let board: String
    let onToken: (String) -> Void

    static let log = Logger(subsystem: Signposts.subsystem, category: "fourchan-browser")

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "ticket")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = UserAgent.current
        webView.navigationDelegate = context.coordinator
        let page = FourchanCaptchaRequest(board: board, thread: nil).pageURL
        context.coordinator.page = page
        webView.loadHTMLString(Self.page(siteKey: siteKey), baseURL: page)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // The content controller holds the coordinator strongly, and the web
        // view holds the controller. Without this the pair outlives the sheet.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ticket")
    }

    /// The site's key as a JavaScript string, safe inside a script element.
    static func literal(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast()).replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func page(siteKey: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;padding:24px 0;display:flex;justify-content:center}</style>
        <script>
        function neechanLoaded() {
          hcaptcha.render('ticket', {
            sitekey: \(literal(siteKey)),
            callback: (token) => webkit.messageHandlers.ticket.postMessage({ token: token }),
            'expired-callback': () => webkit.messageHandlers.ticket.postMessage({ expired: true }),
            'error-callback': (e) => webkit.messageHandlers.ticket.postMessage({ error: String(e) })
          });
        }
        </script>
        <script src="https://js.hcaptcha.com/1/api.js?onload=neechanLoaded&render=explicit&recaptchacompat=off" async defer></script>
        </head><body><div id="ticket"></div></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let onToken: (String) -> Void
        var page: URL?

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            if let token = body["token"] as? String, !token.isEmpty {
                TicketCaptchaWebView.log.notice("the further check was answered")
                onToken(token)
            } else if let error = body["error"] as? String {
                TicketCaptchaWebView.log.error("the further check failed: \(error, privacy: .public)")
            }
        }

        /// Keeps the sheet on its page; the widget's own frames come from
        /// hCaptcha and go nowhere else.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let destination = navigationAction.request.url
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if isMainFrame {
                decisionHandler(destination == page || destination?.scheme == "about" ? .allow : .cancel)
                return
            }
            let host = destination?.host() ?? ""
            let allowed = destination?.scheme == "about"
                || host == "hcaptcha.com" || host.hasSuffix(".hcaptcha.com")
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
#endif
