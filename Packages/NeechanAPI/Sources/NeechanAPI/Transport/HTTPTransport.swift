import Foundation

/// One HTTP exchange.
///
/// Everything the API layer needs to reach the network goes through this seam,
/// so tests can drive the client from recorded fixtures without a server and
/// without `URLProtocol` swizzling.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPReply
}

/// A completed HTTP response.
public struct HTTPReply: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let url: URL?

    public init(data: Data, statusCode: Int, headers: [String: String] = [:], url: URL? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
    }

    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.statusCode = response.statusCode
        self.headers = Dictionary(
            uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value in
                guard let key = key as? String else { return nil }
                return (key.lowercased(), String(describing: value))
            }
        )
        self.url = response.url
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The `Content-Type` with any parameters (charset, boundary) stripped.
    public var contentType: String? {
        header("content-type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
