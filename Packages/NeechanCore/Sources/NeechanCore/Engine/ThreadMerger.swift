import Foundation
import NeechanAPI

/// Folds a freshly fetched payload into the posts already on screen.
///
/// Pure and synchronous: given the same inputs it always produces the same
/// result, which is what makes the thread view's refresh behaviour testable
/// without a network or a database.
public enum ThreadMerger {
    /// Which kind of fetch produced `incoming`.
    public enum Mode: Sendable, Equatable {
        /// The whole thread, from `/{board}/res/{num}.json`.
        case full
        /// Posts from `/api/mobile/v2/after/…`, which echoes the anchor first.
        case incremental(anchor: Int)
    }

    /// What changed, in terms the view and the store both need.
    public struct Result: Sendable {
        /// The merged thread, ascending by post number.
        public var posts: [Post]
        /// Posts that were not there before.
        public var newPostNums: [Int]
        /// Posts whose content changed, for example by gaining a ban marker.
        public var updatedPostNums: [Int]
        /// Posts the server no longer returns, so they were deleted.
        public var deletedPostNums: [Int]
        /// Posts an endless thread rolled off its head. Not deletions.
        public var trimmedPostNums: [Int]
        /// The incremental reply did not line up; fetch the whole thread.
        public var needsFullReload: Bool

        public var hasChanges: Bool {
            !newPostNums.isEmpty || !updatedPostNums.isEmpty
                || !deletedPostNums.isEmpty || !trimmedPostNums.isEmpty
        }
    }

    /// - Parameters:
    ///   - existing: posts already held, in any order.
    ///   - incoming: the posts just fetched.
    ///   - mode: which endpoint produced `incoming`.
    ///   - isEndless: whether the thread cycles, dropping its oldest posts.
    ///   - keepDeletedPosts: keep deleted posts in place so replies to them
    ///     still make sense. Turning this off backs the "clear deleted" action.
    public static func merge(
        existing: [Post],
        incoming: [Post],
        mode: Mode,
        isEndless: Bool = false,
        keepDeletedPosts: Bool = true
    ) -> Result {
        switch mode {
        case .full:
            mergeFull(
                existing: existing,
                incoming: incoming,
                isEndless: isEndless,
                keepDeletedPosts: keepDeletedPosts
            )
        case .incremental(let anchor):
            mergeIncremental(existing: existing, incoming: incoming, anchor: anchor)
        }
    }

    // MARK: Full

    private static func mergeFull(
        existing: [Post],
        incoming: [Post],
        isEndless: Bool,
        keepDeletedPosts: Bool
    ) -> Result {
        let existingByNum = Dictionary(existing.map { ($0.num, $0) }, uniquingKeysWith: { _, last in last })
        let incomingNums = Set(incoming.map(\.num))

        var newPostNums: [Int] = []
        var updatedPostNums: [Int] = []
        for post in incoming {
            if let previous = existingByNum[post.num] {
                if previous != post { updatedPostNums.append(post.num) }
            } else {
                newPostNums.append(post.num)
            }
        }

        // A post the server stopped returning is either deleted or, in an
        // endless thread, simply rolled off the front. The difference is where
        // it sits relative to the oldest post still being served.
        let oldestIncoming = incoming.map(\.num).min()
        var deletedPostNums: [Int] = []
        var trimmedPostNums: [Int] = []
        for post in existing where !incomingNums.contains(post.num) {
            if isEndless, let oldestIncoming, post.num < oldestIncoming {
                trimmedPostNums.append(post.num)
            } else {
                deletedPostNums.append(post.num)
            }
        }

        var posts = incoming
        if keepDeletedPosts {
            let deleted = Set(deletedPostNums)
            posts.append(contentsOf: existing.filter { deleted.contains($0.num) })
        }
        posts.sort { $0.num < $1.num }

        return Result(
            posts: posts,
            newPostNums: newPostNums.sorted(),
            updatedPostNums: updatedPostNums.sorted(),
            deletedPostNums: deletedPostNums.sorted(),
            trimmedPostNums: trimmedPostNums.sorted(),
            needsFullReload: false
        )
    }

    // MARK: Incremental

    private static func mergeIncremental(
        existing: [Post],
        incoming: [Post],
        anchor: Int
    ) -> Result {
        // The endpoint returns posts numbered `anchor` and above, so the anchor
        // itself must come back. If it does not, the thread was pruned or
        // renumbered underneath us and only a full load can be trusted.
        guard let first = incoming.first, first.num <= anchor else {
            return Result(
                posts: existing.sorted { $0.num < $1.num },
                newPostNums: [], updatedPostNums: [], deletedPostNums: [], trimmedPostNums: [],
                needsFullReload: true
            )
        }

        var byNum = Dictionary(existing.map { ($0.num, $0) }, uniquingKeysWith: { _, last in last })
        var newPostNums: [Int] = []
        var updatedPostNums: [Int] = []

        for post in incoming {
            if let previous = byNum[post.num] {
                if previous != post {
                    updatedPostNums.append(post.num)
                    byNum[post.num] = post
                }
            } else {
                newPostNums.append(post.num)
                byNum[post.num] = post
            }
        }

        return Result(
            posts: byNum.values.sorted { $0.num < $1.num },
            newPostNums: newPostNums.sorted(),
            updatedPostNums: updatedPostNums.sorted(),
            deletedPostNums: [],
            trimmedPostNums: [],
            needsFullReload: false
        )
    }
}
