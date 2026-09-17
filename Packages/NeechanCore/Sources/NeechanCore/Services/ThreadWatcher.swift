import Foundation
import NeechanAPI
import NeechanSettings
import SwiftData

/// Polls watched threads for new posts.
///
/// Uses `/api/mobile/v2/info`, which returns only a count: a watcher checking
/// twenty threads must not download twenty threads.
public actor ThreadWatcher {
    /// What one poll found.
    public struct Result: Sendable, Equatable {
        public let key: ThreadKey
        public let newPostCount: Int
        public let isDeleted: Bool

        public var hasNews: Bool { newPostCount > 0 }
    }

    private let client: DvachClient
    /// Which imageboard the watcher is following, read fresh each pass: the
    /// reader can switch sites while this actor is asleep.
    private let site: SiteProvider
    private let favorites: FavoritesRepository
    private let states: WatchedThreadStore
    private var pollTask: Task<Void, Never>?
    /// Threads being polled right now.
    ///
    /// The loop and the Favorites screen can both ask at once, and without this
    /// they each sent their own request for the same thread.
    private var inFlight: Set<ThreadKey> = []
    /// The device and preference state a poll has to respect, asked afresh each
    /// pass. A closure rather than a value because the answer lives on the main
    /// actor and changes while this actor is asleep.
    private var conditions: @Sendable () async -> PollConditions

    /// When each thread is next worth asking about.
    ///
    /// Held in memory and seeded from the store as threads are first seen, so
    /// the dedupe survives a relaunch without a schema change. The backoff
    /// count starts again at the reader's interval after a launch, which is the
    /// right way round: someone who has just opened the app wants to be told.
    private var scheduleStates: [ThreadKey: WatcherSchedule.ThreadState] = [:]
    private var schedule = WatcherSchedule(baseInterval: .seconds(60))

    /// How many threads are asked about at once.
    ///
    /// The radio costs far more to wake than to keep awake, so a pass that
    /// finishes quickly is cheaper than the same requests spread thin. Small
    /// enough not to look like a flood to the site.
    static let concurrentPolls = 3

    /// The longest a thread is ever left, and where closed threads sit.
    static let closedThreadInterval = Duration.seconds(900)

    public init(
        client: DvachClient,
        site: @escaping SiteProvider,
        favorites: FavoritesRepository,
        states: WatchedThreadStore,
        conditions: @escaping @Sendable () async -> PollConditions = { .unrestricted }
    ) {
        self.client = client
        self.site = site
        self.favorites = favorites
        self.states = states
        self.conditions = conditions
    }

    /// Drops everything in flight and everything scheduled.
    ///
    /// Called when the imageboard changes. A poll already awaiting a reply
    /// would otherwise come back against the new site and write its count onto
    /// the old site's thread — so the answer has to be abandoned, not merely
    /// ignored. The per-thread guard in `poll` is the second half of that.
    public func reset() {
        pollTask?.cancel()
        pollTask = nil
        inFlight.removeAll()
        scheduleStates.removeAll()
    }

    /// Points the watcher at the live device and preference state.
    ///
    /// Set after construction because it reads the main actor, which does not
    /// exist to be read while the services are still being built.
    public func setConditions(_ conditions: @escaping @Sendable () async -> PollConditions) {
        self.conditions = conditions
    }

    deinit {
        pollTask?.cancel()
    }

    /// Polls every watched thread once and reports what changed.
    ///
    /// Asks about everything that is not gone. Pull to refresh on the Favorites
    /// screen is the caller with a right to that; the loop uses `pollDue`.
    @discardableResult
    public func pollOnce() async -> [Result] {
        await pollOnce(skippingPolledWithin: nil)
    }

    /// Polls the threads the schedule says are due.
    ///
    /// - Parameter deadline: when to stop starting new requests. The background
    ///   task is given a few seconds by the system and killed if it overruns, so
    ///   it asks about what it can and leaves the rest for next time.
    @discardableResult
    public func pollDue(
        now: Date = .now,
        deadline: ContinuousClock.Instant? = nil
    ) async -> [Result] {
        let conditions = await conditions()
        guard conditions.allowsPolling else { return [] }
        guard let keys = try? await favorites.watchedKeys(site: site().site), !keys.isEmpty else { return [] }

        await seedSchedule(for: keys)
        let due = schedule
            .due(keys, states: scheduleStates, at: now, lowPower: conditions.isLowPower)
            .filter { !inFlight.contains($0) }
        guard !due.isEmpty else { return [] }

        return await pollConcurrently(due, deadline: deadline)
    }

    /// How long to sleep before the next pass.
    public func timeUntilNextPoll(now: Date = .now) async -> Duration {
        let conditions = await conditions()
        guard
            let keys = try? await favorites.watchedKeys(site: site().site), !keys.isEmpty
        else {
            return schedule.baseInterval
        }
        guard
            let wake = schedule.nextWake(
                keys, states: scheduleStates, at: now, lowPower: conditions.isLowPower
            )
        else {
            // Nothing is ever due again — every favourite is gone. Wait the long
            // interval rather than spinning; a new favourite restarts the loop.
            return schedule.maxInterval
        }
        return .seconds(max(1, wake.timeIntervalSince(now)))
    }

    /// Polls the watched threads, leaving out any polled recently.
    ///
    /// Opening the Favorites tab asks for this: a reader coming straight back
    /// to it should see the list at once rather than wait for one request per
    /// favourite, which is what a full poll costs.
    ///
    /// - Parameter skippingPolledWithin: how recent counts as recent enough to
    ///   leave alone. Nil polls everything.
    @discardableResult
    public func pollOnce(skippingPolledWithin age: Duration?) async -> [Result] {
        guard await conditions().allowsPolling else { return [] }
        guard let keys = try? await favorites.watchedKeys(site: site().site), !keys.isEmpty else { return [] }

        var results: [Result] = []
        for key in keys {
            guard !Task.isCancelled else { break }
            guard !inFlight.contains(key) else { continue }
            guard await isDue(key, within: age) else { continue }

            inFlight.insert(key)
            defer { inFlight.remove(key) }
            if let result = await poll(key) {
                results.append(result)
            }
        }
        return results
    }

    /// Whether this thread is worth asking about now.
    ///
    /// A thread the site has stopped serving will never come back, so it is
    /// never asked about again; a closed one can gain no posts, so it is asked
    /// about rarely rather than at the reader's interval. Between them these
    /// are most of what a long-lived favourites list holds.
    private func isDue(_ key: ThreadKey, within age: Duration?) async -> Bool {
        guard let state = try? await states.state(for: key) else { return true }
        if state.isDeleted { return false }

        let window = state.isClosed ? max(age ?? .zero, Self.closedThreadInterval) : age
        guard let window else { return true }
        return Date.now.timeIntervalSince(state.lastPolledAt) >= window.seconds
    }

    /// Reads what the store knows about threads the schedule has not seen yet.
    private func seedSchedule(for keys: [ThreadKey]) async {
        for key in keys where scheduleStates[key] == nil {
            guard let stored = try? await states.state(for: key) else {
                scheduleStates[key] = WatcherSchedule.ThreadState()
                continue
            }
            scheduleStates[key] = WatcherSchedule.ThreadState(
                lastPolledAt: stored.lastPolledAt,
                quietPolls: 0,
                isClosed: stored.isClosed,
                isDeleted: stored.isDeleted
            )
        }
    }

    /// Asks about several threads at once, a few at a time.
    private func pollConcurrently(
        _ keys: [ThreadKey],
        deadline: ContinuousClock.Instant?
    ) async -> [Result] {
        // A site that answers for a whole board at once is asked that way
        // instead: twenty favourites across three boards cost three requests
        // rather than twenty, which is cheaper than the per-thread poll it
        // replaces rather than a compromise for the lack of one.
        if site().capabilities.boardWidePoll {
            return await pollByBoard(keys)
        }
        var pending = ArraySlice(keys)
        var results: [Result] = []

        await withTaskGroup(of: (ThreadKey, Result?).self) { group in
            var running = 0

            func startNext() {
                guard let key = pending.popFirst() else { return }
                inFlight.insert(key)
                running += 1
                group.addTask { [self] in
                    (key, await poll(key))
                }
            }

            for _ in 0..<min(Self.concurrentPolls, keys.count) { startNext() }

            while running > 0, let (key, result) = await group.next() {
                running -= 1
                inFlight.remove(key)
                if let result { results.append(result) }

                guard !Task.isCancelled else { continue }
                if let deadline, ContinuousClock.now >= deadline { continue }
                startNext()
            }
        }
        return results
    }

    /// Asks each board once and reads every watched thread out of the answer.
    private func pollByBoard(_ keys: [ThreadKey]) async -> [Result] {
        var results: [Result] = []
        for (board, keys) in Dictionary(grouping: keys, by: \.boardRef) {
            guard !Task.isCancelled else { break }
            for key in keys { inFlight.insert(key) }
            defer { for key in keys { inFlight.remove(key) } }

            let counts: [Int: ThreadCount]
            do {
                counts = try await client.boardThreadCounts(board: board.code)
            } catch {
                for key in keys {
                    try? await states.recordFailure(key, message: error.readableWatcherMessage)
                    record(key, outcome: isRateLimited(error) ? .rateLimited : .failure)
                }
                continue
            }
            // The reader can switch imageboards while this is in the air.
            guard board.site == site().site else { continue }

            for key in keys {
                guard let count = counts[key.threadNum] else {
                    // Absent from the board's list means it has fallen off the
                    // last page, not that it was deleted: it may still be
                    // readable in the archive. Recorded as closed, which is
                    // also the longest the schedule will leave it.
                    try? await states.record(
                        key: key,
                        postsCount: (try? await states.state(for: key))?.lastKnownPostsCount ?? 0,
                        maxNum: 0,
                        isDeleted: false,
                        isClosed: true
                    )
                    record(key, outcome: .quiet)
                    continue
                }

                let known = try? await states.state(for: key)
                let previous = known?.lastKnownPostsCount ?? count.postsCount
                let newPosts = max(0, count.postsCount - previous)
                try? await states.record(
                    key: key,
                    postsCount: count.postsCount,
                    maxNum: known?.lastKnownMaxNum ?? 0,
                    isDeleted: false
                )
                record(key, outcome: newPosts > 0 ? .news : .quiet)
                if newPosts > 0 || known == nil {
                    results.append(Result(key: key, newPostCount: newPosts, isDeleted: false))
                }
            }
        }
        return results
    }

    /// Polls one thread.
    private func poll(_ key: ThreadKey) async -> Result? {
        // The reader can switch imageboards mid-pass. A reply that arrives
        // after that belongs to a site this key is not on, and writing it would
        // corrupt the other site's unread count.
        guard key.site == site().site else { return nil }
        let known = try? await states.state(for: key)

        do {
            let response = try await client.threadInfo(board: key.board, thread: key.threadNum)
            guard key.site == site().site else { return nil }
            guard let info = response.thread else {
                record(key, outcome: .quiet)
                return nil
            }

            // `posts` excludes the opening post, so the thread's total is one more.
            let total = info.posts + 1
            let previous = known?.lastKnownPostsCount ?? total
            let newPosts = max(0, total - previous)

            try? await states.record(
                key: key,
                postsCount: total,
                maxNum: max(known?.lastKnownMaxNum ?? 0, info.num),
                isDeleted: false
            )
            record(key, outcome: newPosts > 0 ? .news : .quiet)
            return Result(key: key, newPostCount: newPosts, isDeleted: false)
        } catch {
            // A thread that is gone stays gone; anything else is a hiccup and
            // must not make the reader think their thread was deleted.
            let isMissing = error.code?.meansMissing == true || isNotFound(error)
            if isMissing {
                try? await states.markDeleted(key)
                record(key, outcome: .deleted)
                return Result(key: key, newPostCount: 0, isDeleted: true)
            }
            try? await states.recordFailure(key, message: error.readableWatcherMessage)
            record(key, outcome: isRateLimited(error) ? .rateLimited : .failure)
            return nil
        }
    }

    /// Notes what a poll found, so the next one is scheduled accordingly.
    private func record(_ key: ThreadKey, outcome: WatcherSchedule.Outcome) {
        let state = scheduleStates[key] ?? WatcherSchedule.ThreadState()
        scheduleStates[key] = schedule.afterPoll(state, outcome: outcome, at: .now)
    }

    private func isRateLimited(_ error: DvachError) -> Bool {
        if case .http(let status, _) = error { return status == 429 }
        return false
    }

    // MARK: Scheduling

    /// Polls repeatedly while the app is in front.
    ///
    /// Background refresh is opportunistic and may not run for hours, so the
    /// foreground timer is what readers actually notice.
    public func startPolling(
        every interval: Duration,
        onResults: (@Sendable ([Result]) async -> Void)? = nil
    ) {
        stopPolling()
        schedule = WatcherSchedule(
            baseInterval: interval, maxInterval: Self.closedThreadInterval
        )
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Only what the schedule says is due. Starting the loop is
                // therefore nearly free, which matters because it is started
                // again every time the app comes to the front: a notification
                // banner used to cost a request per favourite.
                let results = await self.pollDue()
                await onResults?(results)
                // Sleeps until the soonest thread is due rather than for a fixed
                // stretch after the pass, so the period does not drift by however
                // long the requests took.
                let wait = await self.timeUntilNextPoll()
                try? await Task.sleep(for: wait)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func isNotFound(_ error: DvachError) -> Bool {
        if case .http(let status, _) = error { return status == 404 }
        return false
    }
}

extension DvachError {
    /// Short description kept against a watched thread, for the UI to explain
    /// why a poll produced nothing.
    var readableWatcherMessage: String {
        switch self {
        case .transport: "offline"
        case .cloudflareChallenge: "blocked by a browser check"
        case .http(let status, _): "server error \(status)"
        case .api(let error): error.message
        case .decoding: "unexpected response"
        case .unsupported: "not available on this imageboard"
        }
    }
}


extension Duration {
    /// The duration in seconds, for comparing against a `Date` interval.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
