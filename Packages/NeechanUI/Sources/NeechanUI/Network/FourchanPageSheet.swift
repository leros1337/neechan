import NeechanAPI
import os
import SwiftUI
#if canImport(WebKit) && os(iOS)
import UIKit
import WebKit

/// One of 4chan's own pages, opened from something the captcha said.
///
/// The site's wait message links to the page where the reader verifies their
/// email, which is what lets them post sooner. Whatever that page sets has to
/// land where the captcha's requests will find it — the browser engine's
/// shared store — so it opens here rather than in Safari, whose cookies the
/// app never sees.
struct FourchanPageSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    /// Whether a link belongs here rather than in the system browser.
    static func handles(_ url: URL) -> Bool {
        FourchanPageWebView.isFourchan(url)
    }

    var body: some View {
        NavigationStack {
            FourchanPageWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text(verbatim: url.host() ?? "4chan"))
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

private struct FourchanPageWebView: UIViewRepresentable {
    let url: URL

    static let log = Logger(subsystem: Signposts.subsystem, category: "fourchan-browser")

    static func isFourchan(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), url.scheme?.lowercased() == "https" else { return false }
        return ["4chan.org", "4channel.org", "4cdn.org"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The shared store: the point of opening it here at all.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = UserAgent.current
        webView.navigationDelegate = context.coordinator
        Self.log.notice("opening \(url.absoluteString, privacy: .public)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The page stays on 4chan; a link anywhere else goes to the system
        /// browser. Frames inside it — a check, a captcha — load as they need.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame ?? true,
                  let destination = navigationAction.request.url,
                  destination.scheme?.lowercased() != "about",
                  !FourchanPageWebView.isFourchan(destination)
            else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            UIApplication.shared.open(destination)
        }
    }
}
#endif
