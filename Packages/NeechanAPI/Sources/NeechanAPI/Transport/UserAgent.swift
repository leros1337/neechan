import Foundation
import Synchronization

/// The user agent every request presents.
///
/// One value for the whole app, because the site is behind Cloudflare and the
/// `cf_clearance` cookie is bound to the agent that earned it: the API calls,
/// the file downloads, the video engine and the browser check must all speak as
/// the same client or the cookie is refused.
///
/// Held here rather than composed from a literal so the app can replace it at
/// launch with what this device's own browser engine sends. This package stays
/// free of WebKit; the layer that has it pushes the value down.
public enum UserAgent {
    /// Used until the device's own agent has been read, and if it cannot be.
    ///
    /// A plausible Safari string rather than a made-up one: a request has to go
    /// out before the real agent is known, and it has to be accepted.
    public static let fallback =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    private static let storage = Mutex<String>(fallback)

    /// The agent to send now.
    ///
    /// Read per request rather than captured, so a value that arrives after a
    /// client was built still applies to everything it sends afterwards.
    public static var current: String {
        storage.withLock { $0 }
    }

    /// Adopts the device's own agent. Blank values are ignored, since an empty
    /// header is worse than the fallback.
    public static func set(_ agent: String) {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        storage.withLock { $0 = trimmed }
    }

    /// Puts the fallback back. For tests, which must not leak a value into the
    /// next one.
    public static func reset() {
        storage.withLock { $0 = fallback }
    }
}
