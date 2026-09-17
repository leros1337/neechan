import Foundation

/// Recognises an anti-bot interstitial served in place of the response.
///
/// 2ch sits behind Cloudflare and also runs its own "Проверка..." gate; 4chan
/// serves a script that computes a cookie in the browser before it will answer.
/// All of them answer with an HTML page rather than JSON, sometimes under a
/// 200. Spotting that early lets the app show a web view so the user can pass
/// the check, instead of reporting a confusing decoding failure.
public enum ChallengeDetector {
    /// Markers that appear in the body of a gate page.
    private static let bodyMarkers = [
        "<title>Проверка",
        "cf-challenge",
        "challenge-platform",
        "cf_chl_opt",
        "__cf_chl",
        "Just a moment",
        // 4chan's own interstitial: a page whose whole body is a script setting
        // `_tcs` from the clock, the timezone and the length of `eval`'s source,
        // which then reloads itself. It carries none of Cloudflare's markers and
        // not even a title, so the cookie's name is what identifies it.
        "_tcs=",
    ]

    /// Which marker identified the gate, for diagnosis. Nil when it is not one.
    public static func matchedMarker(_ reply: HTTPReply) -> String? {
        if reply.header("cf-mitigated") != nil { return "cf-mitigated" }
        guard reply.contentType == "text/html" else { return nil }
        let text = String(decoding: reply.data.prefix(4096), as: UTF8.self)
        return bodyMarkers.first { text.localizedCaseInsensitiveContains($0) }
    }

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
