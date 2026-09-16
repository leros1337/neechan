import Foundation

/// Decides which watched threads are worth asking about, and when to wake up
/// next to ask.
///
/// Pure, so the whole policy can be tested without a network or a clock. The
/// watcher keeps the state; this says what to do with it.
public struct WatcherSchedule: Sendable, Equatable {
    /// What the watcher remembers about one thread between polls.
    public struct ThreadState: Sendable, Equatable {
        public var lastPolledAt: Date
        /// Consecutive polls that brought nothing.
        public var quietPolls: Int
        /// Closed to new posts, so it can never have news again.
        public var isClosed: Bool
        /// The site has stopped serving it.
        public var isDeleted: Bool

        public init(
            lastPolledAt: Date = .distantPast,
            quietPolls: Int = 0,
            isClosed: Bool = false,
            isDeleted: Bool = false
        ) {
            self.lastPolledAt = lastPolledAt
            self.quietPolls = quietPolls
            self.isClosed = isClosed
            self.isDeleted = isDeleted
        }
    }

    /// What one poll found, as far as scheduling the next one is concerned.
    public enum Outcome: Sendable, Equatable {
        case news
        case quiet
        case failure
        /// The site asked us to slow down.
        case rateLimited
        case deleted
    }

    /// The interval the reader chose.
    public var baseInterval: Duration
    /// The longest a thread is ever left, and where closed threads sit.
    public var maxInterval: Duration

    public init(baseInterval: Duration, maxInterval: Duration = .seconds(900)) {
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
    }

    /// How long this thread should be left alone, or nil if it never needs
    /// asking about again.
    public func interval(for state: ThreadState, lowPower: Bool = false) -> Duration? {
        if state.isDeleted { return nil }
        if state.isClosed { return maxInterval }
        return PollBackoff.interval(
            base: baseInterval,
            quiet: state.quietPolls,
            cap: maxInterval,
            lowPower: lowPower
        )
    }

    /// When this thread is next worth asking about, or nil if never.
    public func nextPoll(for state: ThreadState, lowPower: Bool = false) -> Date? {
        guard let interval = interval(for: state, lowPower: lowPower) else { return nil }
        return state.lastPolledAt.addingTimeInterval(interval.seconds)
    }

    /// The threads worth asking about now, oldest first.
    ///
    /// Oldest first so that a pass cut short by a deadline — the background task
    /// has one — spends what time it has on whatever has been waiting longest,
    /// rather than on whichever favourite happens to sort first.
    public func due(
        _ keys: [ThreadKey],
        states: [ThreadKey: ThreadState],
        at now: Date,
        lowPower: Bool = false
    ) -> [ThreadKey] {
        keys
            .compactMap { key -> (ThreadKey, Date)? in
                // Never asked about: due at once, and first.
                guard let state = states[key] else { return (key, .distantPast) }
                guard let next = nextPoll(for: state, lowPower: lowPower) else { return nil }
                guard next <= now else { return nil }
                return (key, state.lastPolledAt)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// When the watcher should wake up next, or nil when nothing is ever due
    /// again.
    public func nextWake(
        _ keys: [ThreadKey],
        states: [ThreadKey: ThreadState],
        at now: Date,
        lowPower: Bool = false
    ) -> Date? {
        keys
            .compactMap { key -> Date? in
                guard let state = states[key] else { return now }
                return nextPoll(for: state, lowPower: lowPower)
            }
            .min()
    }

    /// The state to keep after a poll.
    public func afterPoll(_ state: ThreadState, outcome: Outcome, at now: Date) -> ThreadState {
        var next = state
        next.lastPolledAt = now

        switch outcome {
        case .news:
            next.quietPolls = 0
        case .quiet, .failure:
            next.quietPolls += 1
        case .rateLimited:
            // Straight to the longest wait the schedule has. Being asked to
            // slow down and then backing off one step at a time is how a
            // client gets itself blocked.
            next.quietPolls = quietPollsAtCap
        case .deleted:
            next.isDeleted = true
        }
        return next
    }

    /// The quiet count at which a thread sits at the cap.
    private var quietPollsAtCap: Int {
        var polls = 0
        while polls < 64,
              PollBackoff.interval(base: baseInterval, quiet: polls, cap: maxInterval) < maxInterval
        {
            polls += 1
        }
        return polls
    }
}
