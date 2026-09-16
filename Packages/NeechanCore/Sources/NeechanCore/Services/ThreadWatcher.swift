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
    private let favorites: FavoritesRepository
    private let states: WatchedThreadStore
    private var pollTask: Task<Void, Never>?

    public init(
        client: DvachClient,
        favorites: FavoritesRepository,
        states: WatchedThreadStore
    ) {
        self.client = client
        self.favorites = favorites
        self.states = states
    }

    deinit {
        pollTask?.cancel()
    }

    /// Polls every watched thread once and reports what changed.
    @discardableResult
    public func pollOnce() async -> [Result] {
        await pollOnce(skippingPolledWithin: nil)
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
        guard let keys = try? await favorites.watchedKeys(), !keys.isEmpty else { return [] }

        var results: [Result] = []
        for key in keys {
            guard !Task.isCancelled else { break }
            if let age, await wasPolled(key, within: age) { continue }
            if let result = await poll(key) {
                results.append(result)
            }
        }
        return results
    }

    /// Whether this thread was polled inside the given window.
    private func wasPolled(_ key: ThreadKey, within age: Duration) async -> Bool {
        guard let state = try? await states.state(for: key) else { return false }
        return Date.now.timeIntervalSince(state.lastPolledAt) < Double(age.components.seconds)
    }

    /// Polls one thread.
    private func poll(_ key: ThreadKey) async -> Result? {
        let known = try? await states.state(for: key)

        do {
            let response = try await client.threadInfo(board: key.board, thread: key.threadNum)
            guard let info = response.thread else { return nil }

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
            return Result(key: key, newPostCount: newPosts, isDeleted: false)
        } catch {
            // A thread that is gone stays gone; anything else is a hiccup and
            // must not make the reader think their thread was deleted.
            let isMissing = error.code?.meansMissing == true || isNotFound(error)
            if isMissing {
                try? await states.markDeleted(key)
                return Result(key: key, newPostCount: 0, isDeleted: true)
            }
            try? await states.recordFailure(key, message: error.readableWatcherMessage)
            return nil
        }
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
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let results = await self?.pollOnce() ?? []
                await onResults?(results)
                try? await Task.sleep(for: interval)
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
        }
    }
}
