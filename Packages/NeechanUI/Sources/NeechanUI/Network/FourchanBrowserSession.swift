import Foundation
import NeechanAPI
import os
import SwiftUI
#if canImport(WebKit) && os(iOS)
import UIKit
import WebKit

/// The browser engine 4chan's captcha and posts go through.
///
/// 4chan's posting host sits behind a script that computes a `_tcs` cookie and
/// behind Cloudflare, and both refuse the app's own requests even when they
/// replay the very cookies a web view earned. So this does what the site's own
/// reply form does, in a web view nobody sees: it holds a page whose address is
/// the board's, puts the captcha frame in it and reads what the frame posts
/// back, and sends the post with that page's `fetch`. The requests leave from
/// the engine, with its cookies, its `Origin` and its `Referer`.
///
/// One web view for the whole app, kept out of sight except while the frame
/// shows a browser check: only a person can answer one, so the form shows
/// this view for as long as it lasts.
///
/// Nothing here looks at a captcha. The frame's object is handed on as it came.
@MainActor
final class FourchanBrowserSession: NSObject, FourchanBrowser {
    static let log = Logger(subsystem: Signposts.subsystem, category: "fourchan-browser")

    /// How long a frame may take before anyone has been shown a check.
    static let frameTimeout = 30_000
    /// How long a check may wait for the reader before it is given up.
    static let checkTimeout = 600_000
    /// What the site's quick reply would wait for an upload.
    static let postTimeout = 120_000

    private(set) lazy var webView: WKWebView = makeWebView()

    private var loadedPage: URL?
    /// The load of `loadedPage`; any other navigation's ending is not its.
    private var pageNavigation: WKNavigation?
    private var isPageReady = false
    private var pageWaiters: [CheckedContinuation<Bool, Never>] = []

    /// The frame being waited on, and who to tell if it shows a check.
    private var frameRequest = 0
    private var onCheck: (@Sendable () -> Void)?
    private var hasReportedCheck = false

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The shared store: a check passed here is passed for the report page
        // and the app's own browser check too, and the other way round.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 120),
            configuration: configuration
        )
        // The same agent the rest of the app sends, or a cookie this earns is
        // refused when anything else presents it.
        webView.customUserAgent = UserAgent.current
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        return webView
    }

    // MARK: FourchanBrowser

    func captchaFrame(
        at frame: URL,
        inPage page: URL,
        onCheck: @escaping @Sendable () -> Void
    ) async throws(FourchanBrowserError) -> Data {
        guard await preparePage(page) else { throw .failed(Self.pageDidNotLoad) }

        frameRequest += 1
        let request = frameRequest
        self.onCheck = onCheck
        hasReportedCheck = false
        defer {
            if frameRequest == request { self.onCheck = nil }
        }

        Self.log.notice("loading the captcha frame for \(page.path(), privacy: .public)")
        let result: Any?
        do {
            let webView = self.webView
            result = try await withTaskCancellationHandler {
                try await webView.callAsyncJavaScript(
                    "return await window.neechan.captcha(src, timeout)",
                    arguments: ["src": frame.absoluteString, "timeout": Self.frameTimeout],
                    in: nil,
                    contentWorld: .page
                )
            } onCancel: {
                Task { @MainActor in
                    _ = try? await webView.evaluateJavaScript("window.neechan && window.neechan.cancel(); 0")
                }
            }
        } catch {
            throw Self.frameError(error)
        }
        guard let json = result as? String else { throw .failed(Self.pageDidNotLoad) }
        Self.log.notice("the captcha frame answered: \(json.utf8.count, privacy: .public) bytes")
        return Data(json.utf8)
    }

    func send(_ request: URLRequest, fromPage page: URL) async throws(FourchanBrowserError) -> HTTPReply {
        guard let url = request.url, let body = request.httpBody else {
            throw .failed(Self.pageDidNotLoad)
        }
        guard await preparePage(page) else { throw .failed(Self.pageDidNotLoad) }

        Self.log.notice("sending a post: \(body.count, privacy: .public) bytes")
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                "return await window.neechan.send(url, body, contentType, accept, timeout)",
                arguments: [
                    "url": url.absoluteString,
                    "body": body.base64EncodedString(),
                    "contentType": request.value(forHTTPHeaderField: "Content-Type") ?? "",
                    "accept": request.value(forHTTPHeaderField: "Accept") ?? "*/*",
                    "timeout": Self.postTimeout,
                ],
                in: nil,
                contentWorld: .page
            )
        } catch {
            // Whatever went wrong, it may have gone wrong after the request
            // left, and calling that unsent would invite a second post.
            Self.log.error("sending failed: \(error.localizedDescription, privacy: .public)")
            throw .unconfirmed(error.localizedDescription)
        }

        guard let answer = result as? [String: Any] else { throw .unconfirmed("no answer") }
        if let reason = answer["unconfirmed"] as? String {
            Self.log.error("the post left and nothing came back: \(reason, privacy: .public)")
            throw .unconfirmed(reason)
        }
        let status = (answer["status"] as? NSNumber)?.intValue ?? 0
        let contentType = answer["contentType"] as? String ?? ""
        let text = answer["text"] as? String ?? ""
        Self.log.notice(
            "the post was answered: \(status, privacy: .public) \(contentType, privacy: .public) \(text.utf8.count, privacy: .public) bytes"
        )
        return HTTPReply(
            data: Data(text.utf8),
            statusCode: status,
            headers: contentType.isEmpty ? [:] : ["content-type": contentType],
            url: (answer["url"] as? String).flatMap(URL.init(string:))
        )
    }

    // MARK: The page

    /// Loads the host page with `page`'s address, unless it already has it.
    private func preparePage(_ page: URL) async -> Bool {
        if loadedPage == page, isPageReady { return true }
        if loadedPage != page {
            loadedPage = page
            isPageReady = false
            // Anyone waiting on the old page is told it will not come.
            finishPageLoad(false)
            pageNavigation = webView.loadHTMLString(Self.hostPage, baseURL: page)
        }
        return await withCheckedContinuation { continuation in
            pageWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finishPageLoad(false, ifStillWaitingOn: continuation)
            }
        }
    }

    private func finishPageLoad(_ ready: Bool) {
        let waiters = pageWaiters
        pageWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    private func finishPageLoad(_ ready: Bool, ifStillWaitingOn continuation: CheckedContinuation<Bool, Never>) {
        // Continuations cannot be compared, so the timeout gives up on every
        // waiter only when the page has still not answered.
        guard !isPageReady, !pageWaiters.isEmpty else { return }
        Self.log.error("the host page did not load in time")
        loadedPage = nil
        finishPageLoad(ready)
    }

    /// Reports the check once per frame, and gives the reader time to answer.
    private func checkSeen() {
        guard !hasReportedCheck, let onCheck else { return }
        hasReportedCheck = true
        Self.log.notice("the captcha frame is showing a browser check")
        onCheck()
        webView.evaluateJavaScript("window.neechan && window.neechan.extend(\(Self.checkTimeout)); 0")
    }

    private static func frameError(_ error: any Error) -> FourchanBrowserError {
        let message = ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ""
        if message.contains("superseded") || message.contains("cancelled") { return .cancelled }
        if message.contains("timeout") { return .timedOut }
        log.error("the captcha frame failed: \(error.localizedDescription, privacy: .public)")
        return .failed(String(localized: "The captcha did not arrive. Try again.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current))
    }

    private static var pageDidNotLoad: String {
        String(localized: "The page the captcha sits in did not load.", bundle: .neechanUI.forAppLanguage(), locale: AppLocale.current)
    }

    /// An empty page that does what the site's reply form does, and no more.
    ///
    /// `captcha` puts the frame in and waits for its `twister` message, from
    /// the posting host and from that frame only, as the site's own script
    /// checks. `send` posts a body the app built, from here, with this page's
    /// cookies. The frame fills the page, so that when a check appears in it
    /// the reader sees the check and nothing else.
    static let hostPage = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;height:100%;overflow:hidden;background:transparent}\
        iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body><script>
        (() => {
          const SYS = 'https://sys.4chan.org';
          let pending = null;
          function settle(ok, value) {
            if (!pending) return;
            const p = pending; pending = null;
            clearTimeout(p.timer); p.frame.remove();
            ok ? p.resolve(value) : p.reject(new Error(value));
          }
          function arm(timeoutMs) {
            clearTimeout(pending.timer);
            pending.timer = setTimeout(() => settle(false, 'timeout'), timeoutMs);
          }
          window.addEventListener('message', (e) => {
            if (!pending || e.origin !== SYS || e.source !== pending.frame.contentWindow) return;
            if (!e.data || !e.data.twister) return;
            settle(true, JSON.stringify(e.data.twister));
          });
          window.neechan = {
            captcha(src, timeoutMs) {
              settle(false, 'superseded');
              return new Promise((resolve, reject) => {
                const frame = document.createElement('iframe');
                pending = { frame, resolve, reject, timer: null };
                arm(timeoutMs);
                frame.src = src;
                document.body.appendChild(frame);
              });
            },
            extend(timeoutMs) { if (pending) arm(timeoutMs); },
            cancel() { settle(false, 'cancelled'); },
            async send(url, body, contentType, accept, timeoutMs) {
              const binary = atob(body);
              const bytes = new Uint8Array(binary.length);
              for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
              let response;
              try {
                response = await fetch(url, {
                  method: 'POST', mode: 'cors', credentials: 'include',
                  headers: { 'Content-Type': contentType, 'Accept': accept },
                  body: bytes, signal: AbortSignal.timeout(timeoutMs)
                });
              } catch (e) {
                return { unconfirmed: String((e && (e.name + ': ' + e.message)) || e) };
              }
              let text = '';
              try { text = await response.text(); } catch (e) {
                return { unconfirmed: String((e && (e.name + ': ' + e.message)) || e) };
              }
              return { status: response.status, contentType: response.headers.get('content-type') || '',
                       url: response.url, text };
            }
          };
        })();
        </script></body></html>
        """
}

extension FourchanBrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === pageNavigation else { return }
        isPageReady = true
        finishPageLoad(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        pageFailed(navigation, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        pageFailed(navigation, error)
    }

    /// A page replaced by a newer one fails too, and says nothing about it.
    private func pageFailed(_ navigation: WKNavigation?, _ error: any Error) {
        guard navigation === pageNavigation else { return }
        Self.log.error("the host page failed: \(error.localizedDescription, privacy: .public)")
        loadedPage = nil
        pageNavigation = nil
        finishPageLoad(false)
    }

    /// Keeps the page where it is.
    ///
    /// The host page is loaded from a string, and the frames inside it go
    /// wherever the site and its check send them. Nothing gets to take the
    /// page itself anywhere else.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame else {
            decisionHandler(.allow)
            return
        }
        let destination = navigationAction.request.url
        if destination == loadedPage || destination?.scheme == "about" {
            decisionHandler(.allow)
        } else {
            Self.log.notice("refused to leave the host page for \(destination?.host() ?? "?", privacy: .public)")
            decisionHandler(.cancel)
        }
    }

    /// Spots a check arriving in the frame, by Cloudflare's own header.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            let mitigated = response.value(forHTTPHeaderField: "cf-mitigated")
            Self.log.notice(
                "frame answered \(response.statusCode, privacy: .public) from \(response.url?.host() ?? "?", privacy: .public) mitigated=\(mitigated ?? "-", privacy: .public)"
            )
            if mitigated != nil {
                checkSeen()
            }
        }
        decisionHandler(.allow)
    }
}

/// The session's web view, in the form, for as long as a check is showing.
///
/// The view is the session's own, moved in and out of this container: the
/// frame inside it is the one the captcha is waiting on, and a new view would
/// be a new frame and a new request.
struct FourchanFrameView: UIViewRepresentable {
    let session: FourchanBrowserSession

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let webView = session.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {}

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }
}
#endif
