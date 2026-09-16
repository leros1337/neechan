import Foundation

/// How often, and how far apart, a failed request is retried.
public struct RetryPolicy: Sendable, Hashable {
    /// Delay before each attempt. The first entry is the initial attempt, so a
    /// policy with four entries makes at most four requests.
    public let backoff: [Duration]

    /// Random spread added to each retry.
    ///
    /// Without it every device that hit the same outage comes back at the same
    /// four moments, which is how a site under load is kept under load.
    public let jitter: Duration

    /// The longest `Retry-After` worth waiting for.
    ///
    /// Past this the request is abandoned rather than held open: the reader is
    /// not waiting a minute for a thread count, and a request kept alive holds
    /// the connection with it.
    public let retryAfterCap: Duration

    public init(
        backoff: [Duration],
        jitter: Duration = .zero,
        retryAfterCap: Duration = .seconds(10)
    ) {
        self.backoff = backoff.isEmpty ? [.zero] : backoff
        self.jitter = jitter
        self.retryAfterCap = retryAfterCap
    }

    /// Matches the delays the site's own web client uses for its mobile API.
    public static let `default` = RetryPolicy(
        backoff: [.zero, .milliseconds(250), .milliseconds(500), .milliseconds(1000)],
        jitter: .milliseconds(250)
    )

    /// One attempt, for calls nobody is waiting on.
    ///
    /// The watcher's: it runs every minute anyway, so a failed poll is better
    /// left to the next pass than retried four times into a site that is
    /// already struggling.
    public static let poll = RetryPolicy(backoff: [.zero])

    /// No retries, for calls that must not be repeated (posting).
    public static let none = RetryPolicy(backoff: [.zero])

    public var maxAttempts: Int { backoff.count }

    /// How long to wait before `attempt`, or nil to give up.
    ///
    /// - Parameters:
    ///   - attempt: zero for the first try, which never waits.
    ///   - retryAfter: what the server asked for, in seconds, when it said.
    ///   - random: a value in 0..<1. Injected so a test can pin the spread.
    public func delay(
        beforeAttempt attempt: Int,
        retryAfter: Double? = nil,
        random: Double = Double.random(in: 0..<1)
    ) -> Duration? {
        guard attempt < backoff.count else { return nil }
        if attempt == 0 { return .zero }

        // What the server asked for wins over the schedule, up to the ceiling.
        if let retryAfter, retryAfter > 0 {
            let asked = Duration.seconds(retryAfter)
            guard asked <= retryAfterCap else { return nil }
            return asked
        }

        let spread = Duration.seconds(jitter.seconds * max(0, min(1, random)))
        return backoff[attempt] + spread
    }
}

extension Duration {
    /// The duration in seconds.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
