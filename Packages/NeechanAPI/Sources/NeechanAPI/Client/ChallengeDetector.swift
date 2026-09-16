import Foundation

/// Recognises an anti-bot interstitial served in place of the response.
///
/// 2ch sits behind Cloudflare and also runs its own "Проверка..." gate. Both
/// answer with an HTML page rather than JSON, sometimes under a 200. Spotting
/// that early lets the app show a web view so the user can pass the check,
/// instead of reporting a confusing decoding failure.
public enum ChallengeDetector {
    /// Markers that appear in the body of a gate page.
    private static let bodyMarkers = [
        "<title>Проверка",
        "cf-challenge",
        "challenge-platform",
        "cf_chl_opt",
        "__cf_chl",
        "Just a moment",
    ]

    public static func isChallenge(_ reply: HTTPReply) -> Bool {
        // Cloudflare labels its own interventions.
        if reply.header("cf-mitigated") != nil { return true }

        // Every endpoint the app calls answers with JSON. HTML means something
        // else replied for it.
        guard reply.contentType == "text/html" else { return false }

        // Read only the head of the body: a gate page announces itself early,
        // and a large HTML error page should not be scanned in full.
        let prefix = reply.data.prefix(4096)
        let text = String(decoding: prefix, as: UTF8.self)
        return bodyMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }
}
