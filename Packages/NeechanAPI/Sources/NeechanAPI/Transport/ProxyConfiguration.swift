import Foundation

/// An HTTP proxy the reader configured.
///
/// A value rather than a dictionary so that "no proxy" is spelled `nil` and a
/// half-filled form cannot reach `URLSession` as a broken configuration.
public struct ProxyConfiguration: Sendable, Equatable {
    public let host: String
    public let port: Int

    /// - Returns: nil when the host is blank or the port is outside 1...65535,
    ///   which is what a cleared or half-typed form looks like.
    public init?(host: String?, port: Int) {
        guard
            let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.isEmpty == false,
            (1...65535).contains(port)
        else {
            return nil
        }
        self.host = trimmed
        self.port = port
    }

    /// The form `URLSessionConfiguration.connectionProxyDictionary` wants.
    ///
    /// Both HTTP and HTTPS are pointed at the same proxy, because the site is
    /// HTTPS and the app has no use for a proxy that only covers plain HTTP.
    public var connectionProxyDictionary: [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            "HTTPSEnable": true,
            "HTTPSProxy": host,
            "HTTPSPort": port,
        ]
    }
}
