import Foundation
import SwiftData

/// What the watcher knows about each thread.
public struct WatchedThreadSnapshot: Sendable, Hashable {
    public var lastReadPostNum: Int
    public var lastKnownMaxNum: Int
    public var lastKnownPostsCount: Int
    /// How many posts the thread held when the reader last left it.
    public var readPostsCount: Int
    public var unreadCount: Int
    /// When the watcher last asked the site about this thread.
    public var lastPolledAt: Date
    public var isDeleted: Bool
    public var isClosed: Bool
    public var scrollAnchorPostNum: Int?
    public var lastError: String?
}

/// Reads and writes the per-thread state the watcher and the thread view share.
@ModelActor
public actor WatchedThreadStore {
    public func state(for key: ThreadKey) throws -> WatchedThreadSnapshot? {
        try stored(key).map(WatchedThreadSnapshot.init)
    }

    /// Notes what a poll saw.
    ///
    /// - Parameter isClosed: write-only-true, like the one `markRead` sets: a
    ///   thread that has fallen off the board does not come back, and a poll
    ///   that cannot see it must not clear what an earlier one established.
    public func record(
        key: ThreadKey,
        postsCount: Int,
        maxNum: Int,
        isDeleted: Bool,
        isClosed: Bool = false
    ) throws {
        let state = try stored(key) ?? insert(key)
        state.lastKnownPostsCount = postsCount
        state.lastKnownMaxNum = max(state.lastKnownMaxNum, maxNum)
        state.isThreadDeleted = isDeleted
        if isClosed { state.isClosed = true }
        state.lastPolledAt = .now
        state.lastError = nil
        // Everything past what the reader has seen is unread.
        state.unreadCount = max(0, postsCount - readCount(state))
        try modelContext.save()
    }

    public func recordFailure(_ key: ThreadKey, message: String) throws {
        let state = try stored(key) ?? insert(key)
        state.lastPolledAt = .now
        state.lastError = message
        try modelContext.save()
    }

    public func markDeleted(_ key: ThreadKey) throws {
        let state = try stored(key) ?? insert(key)
        state.isThreadDeleted = true
        state.lastPolledAt = .now
        try modelContext.save()
    }

    /// Records how far the reader has got, which clears the unread count.
    ///
    /// - Parameter isClosed: whether the thread is closed to new posts. Written
    ///   here because leaving a thread is the only moment the app knows: the
    ///   watcher's endpoint reports a count and nothing else. A closed thread
    ///   will never have news, and the watcher uses this to stop asking about it
    ///   at the reader's interval.
    public func markRead(
        _ key: ThreadKey,
        upTo postNum: Int,
        totalPosts: Int,
        isClosed: Bool = false
    ) throws {
        let state = try stored(key) ?? insert(key)
        state.lastReadPostNum = max(state.lastReadPostNum, postNum)
        state.lastKnownPostsCount = max(state.lastKnownPostsCount, totalPosts)
        state.readPostsCount = max(state.readPostsCount, totalPosts)
        state.unreadCount = max(0, state.lastKnownPostsCount - readCount(state))
        // Only ever set: a thread that closed stays closed, and a stale false
        // from an old snapshot must not reopen it.
        if isClosed { state.isClosed = true }
        try modelContext.save()
    }

    /// Remembers where the reader was, so reopening lands in the same place.
    public func saveScrollAnchor(_ key: ThreadKey, postNum: Int?) throws {
        let state = try stored(key) ?? insert(key)
        state.scrollAnchorPostNum = postNum
        try modelContext.save()
    }

    public func clearUnread(_ key: ThreadKey) throws {
        guard let state = try stored(key) else { return }
        state.unreadCount = 0
        try modelContext.save()
    }

    // MARK: Internals

    /// How many posts the reader is considered to have seen.
    ///
    /// The count the thread held when they last left it. This used to be
    /// all-or-nothing — the whole count if they had reached the very newest
    /// post, otherwise zero — which made the badge on a thread they were part
    /// way through show every post in it rather than the few that were new.
    private func readCount(_ state: WatchedThreadState) -> Int {
        state.readPostsCount
    }

    private func insert(_ key: ThreadKey) -> WatchedThreadState {
        let state = WatchedThreadState(key: key)
        modelContext.insert(state)
        return state
    }

    private func stored(_ key: ThreadKey) throws -> WatchedThreadState? {
        let site = key.site.rawValue
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<WatchedThreadState>(
            predicate: #Predicate {
                $0.siteRaw == site && $0.board == board && $0.threadNum == threadNum
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension WatchedThreadSnapshot {
    init(_ state: WatchedThreadState) {
        self.init(
            lastReadPostNum: state.lastReadPostNum,
            lastKnownMaxNum: state.lastKnownMaxNum,
            lastKnownPostsCount: state.lastKnownPostsCount,
            readPostsCount: state.readPostsCount,
            unreadCount: state.unreadCount,
            lastPolledAt: state.lastPolledAt,
            isDeleted: state.isThreadDeleted,
            isClosed: state.isClosed,
            scrollAnchorPostNum: state.scrollAnchorPostNum,
            lastError: state.lastError
        )
    }
}
