import Foundation

/// How often, and how far apart, a failed request is retried.
public struct RetryPolicy: Sendable, Hashable {
    /// Delay before each attempt. The first entry is the initial attempt, so a
    /// policy with four entries makes at most four requests.
    public let backoff: [Duration]

    public init(backoff: [Duration]) {
        self.backoff = backoff.isEmpty ? [.zero] : backoff
    }

    /// Matches the delays the site's own web client uses for its mobile API.
    public static let `default` = RetryPolicy(backoff: [
        .zero, .milliseconds(250), .milliseconds(500), .milliseconds(1000),
    ])

    /// No retries, for calls that must not be repeated (posting).
    public static let none = RetryPolicy(backoff: [.zero])

    public var maxAttempts: Int { backoff.count }
}
