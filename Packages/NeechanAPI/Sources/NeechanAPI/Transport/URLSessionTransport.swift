import Foundation
import Synchronization

/// The production transport.
///
/// Holds its own `URLSession` so the cookie jar and cache are the app's, not the
/// shared singleton's. 2ch is behind Cloudflare, so the session presents a
/// browser-like user agent; `CloudflareWebView` must present the same one for
/// the cookies it collects to be accepted.
public final class URLSessionTransport: HTTPTransport, Sendable {
    /// Kept as a name callers can still use; the value lives in `UserAgent`.
    public static var defaultUserAgent: String { UserAgent.current }

    /// The session is replaced when the proxy changes, so it is held behind a
    /// lock rather than as a plain `let`.
    private let state: Mutex<URLSession>
    /// Kept so a new session can be built with the same cookie jar and cache.
    private let configuration: URLSessionConfiguration?
    /// An agent for this transport alone, or nil to follow `UserAgent`.
    ///
    /// Almost always nil: the app's agent is read from a web view after this
    /// object exists, so capturing a value here would pin the fallback forever.
    private let overriddenUserAgent: String?

    private var session: URLSession { state.withLock { $0 } }

    private var userAgent: String { overriddenUserAgent ?? UserAgent.current }

    public init(session: URLSession, userAgent: String? = nil) {
        self.state = Mutex(session)
        self.configuration = nil
        self.overriddenUserAgent = userAgent
    }

    private init(configuration: URLSessionConfiguration, userAgent: String?) {
        self.state = Mutex(URLSession(configuration: configuration))
        self.configuration = configuration
        self.overriddenUserAgent = userAgent
    }

    /// Points every later request at this proxy, or at nothing when given nil.
    ///
    /// Requests already in flight keep the session they started on.
    public func setProxy(_ proxy: ProxyConfiguration?) {
        guard let configuration else { return }
        configuration.connectionProxyDictionary = proxy?.connectionProxyDictionary
        let replacement = URLSession(configuration: configuration)
        let previous = state.withLock { session -> URLSession in
            defer { session = replacement }
            return session
        }
        previous.finishTasksAndInvalidate()
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
        configuration.waitsForConnectivity = true
        self.init(configuration: configuration, userAgent: userAgent)
    }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        let request = identifying(request)
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
