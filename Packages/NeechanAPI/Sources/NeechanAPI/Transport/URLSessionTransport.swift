import Foundation
import os

/// The production transport.
///
/// Holds its own `URLSession` so the cookie jar and cache are the app's, not the
/// shared singleton's. 2ch is behind Cloudflare, so the session presents a
/// browser-like user agent; `CloudflareWebView` must present the same one for
/// the cookies it collects to be accepted.
public final class URLSessionTransport: HTTPTransport, Sendable {
    /// Kept as a name callers can still use; the value lives in `UserAgent`.
    public static var defaultUserAgent: String { UserAgent.current }

    private let session: URLSession
    /// An agent for this transport alone, or nil to follow `UserAgent`.
    ///
    /// Almost always nil: the app's agent is read from a web view after this
    /// object exists, so capturing a value here would pin the fallback forever.
    private let overriddenUserAgent: String?

    private var userAgent: String { overriddenUserAgent ?? UserAgent.current }

    public init(session: URLSession, userAgent: String? = nil) {
        self.session = session
        self.overriddenUserAgent = userAgent
    }

    private init(configuration: URLSessionConfiguration, userAgent: String?) {
        self.session = URLSession(configuration: configuration)
        self.overriddenUserAgent = userAgent
    }

    /// Builds a session with a private cookie jar and an on-disk response cache.
    public convenience init(
        cookieStorage: HTTPCookieStorage = .shared,
        cache: URLCache? = nil,
        userAgent: String? = nil
    ) {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = cookieStorage
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 30
        // A ceiling on the whole exchange, retries and waiting for connectivity
        // included. Without one an offline poll tick could stay queued
        // indefinitely, and the next tick would queue another behind it.
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        // Four is enough to load a board's thumbnails without the app opening a
        // socket per visible row.
        configuration.httpMaximumConnectionsPerHost = 4
        self.init(configuration: configuration, userAgent: userAgent)
    }

    /// Names every request that leaves the app.
    ///
    /// The cheapest way to count what the radio is asked to do: attach with
    /// `log stream --predicate 'subsystem == "com.lain.neechan"'` and count the
    /// lines, rather than reading a trace.
    private static let log = Logger(subsystem: Signposts.subsystem, category: "network")

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        let request = identifying(request)
        Self.log.debug("request \(request.url?.path() ?? "?", privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return HTTPReply(data: data, response: http)
    }

    /// Adds the app's user agent, unless the caller named one of its own.
    ///
    /// Split out so a test can check what goes on the wire without a network:
    /// the agent is read here, at send time, which is what lets one read from a
    /// web view after startup reach requests made by clients built before it.
    func identifying(_ request: URLRequest) -> URLRequest {
        guard request.value(forHTTPHeaderField: "User-Agent") == nil else { return request }
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
