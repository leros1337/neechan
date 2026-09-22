import NeechanAPI
import OSLog
import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

/// Asks this device for the user agent its browser engine sends.
///
/// The app used to name a fixed iOS version and WebKit build, which goes stale
/// and can never match the browser check exactly. Reading it from a web view
/// means the two speak as the same client by construction, which matters
/// because the clearance cookie is bound to whoever earned it.
///
/// Lives here because this is the only package that may touch WebKit; the value
/// is pushed down into `UserAgent`, which the lower layers read.
enum NativeUserAgent {
    /// Reads it once and adopts it. Safe to call more than once.
    ///
    /// Leaves the fallback in place if the engine cannot answer, which is worse
    /// than the real thing but better than an empty header.
    @MainActor
    static func adopt() async {
        #if canImport(WebKit) && os(iOS)
        guard !hasAdopted else { return }
        hasAdopted = true

        let webView = WKWebView(frame: .zero)
        guard
            let agent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        else {
            return
        }
        UserAgent.set(agent)
        // Logged because a Cloudflare refusal is usually an argument about who
        // the client claims to be, and this is the answer to that question.
        Logger(subsystem: Signposts.subsystem, category: "network")
            .notice("user agent: \(agent, privacy: .public)")
        #endif
    }

    @MainActor private static var hasAdopted = false
}
