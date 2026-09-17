import Foundation
import NeechanAPI

/// Everything the thread view needs for one render, as a single value.
///
/// Derived state (backlinks, parsed bodies, which posts are the reader's own)
/// is computed here rather than stored, because all of it can be rebuilt from
/// the posts plus a small set of persisted facts.
public struct ThreadSnapshot: Sendable {
    public let key: ThreadKey
    /// Posts in ascending number order.
    public let posts: [Post]
    public let meta: ThreadMeta
    /// Backlinks and parsed comment bodies.
    public let index: ReplyIndex
    /// Posts the server stopped returning.
    public let deletedPostNums: Set<Int>
    /// Posts made from this device.
    public let ownPostNums: Set<Int>

    /// Bumped by the repository each time it builds a new snapshot.
    ///
    /// A snapshot is a value with no cheap identity: comparing two of them means
    /// comparing every post. This lets the view tell "the same snapshot I am
    /// already showing" from "a new one" in a single integer compare, which is
    /// what stops a refresh that found nothing from re-rendering the thread.
    public let generation: Int

    /// Whether any post carries a file.
    ///
    /// Stored because the thread view asks on every render to decide whether the
    /// gallery is worth offering, and the only other way to answer was to build
    /// the whole list of attachments and look at its count.
    public let hasAttachments: Bool

    /// Whether any post carries a video.
    ///
    /// Stored for the same reason as `hasAttachments`, and asked by the thread
    /// view to decide whether a feed of the thread's videos is worth offering.
    ///
    /// Answered from the declared type, because this module cannot see
    /// `MediaKind` — NeechanCore does not depend on NeechanMedia. That makes it
    /// a *cheap* answer rather than the last word: a screen acting on it should
    /// still cope with finding nothing once it resolves the files properly.
    public let hasVideos: Bool

    private let positionByNum: [Int: Int]

    public init(
        key: ThreadKey,
        posts: [Post],
        meta: ThreadMeta,
        index: ReplyIndex,
        deletedPostNums: Set<Int> = [],
        ownPostNums: Set<Int> = [],
        generation: Int = 0
    ) {
        self.key = key
        self.posts = posts
        self.meta = meta
        self.index = index
        self.deletedPostNums = deletedPostNums
        self.ownPostNums = ownPostNums
        self.generation = generation
        self.positionByNum = Dictionary(
            uniqueKeysWithValues: posts.enumerated().map { ($0.element.num, $0.offset) }
        )
        self.hasAttachments = posts.contains { !$0.files.isEmpty }
        self.hasVideos = posts.contains { $0.files.contains(where: \.isVideo) }
    }

    public static func empty(key: ThreadKey) -> ThreadSnapshot {
        ThreadSnapshot(key: key, posts: [], meta: .empty, index: ReplyIndex(thread: key))
    }

    public var isEmpty: Bool { posts.isEmpty }

    public var originalPost: Post? { posts.first { $0.isOriginalPost } ?? posts.first }

    public func post(num: Int) -> Post? {
        positionByNum[num].map { posts[$0] }
    }

    /// Position of a post in the thread, counting the opening post as one.
    ///
    /// The server supplies this for posts fetched as part of a thread; for the
    /// rest it is derived from where the post sits in the list.
    public func indexInThread(of post: Post) -> Int? {
        if let number = post.number, number > 0 { return number }
        return position(of: post.num).map { $0 + 1 }
    }

    /// Zero-based row of `num`, for scrolling.
    public func position(of num: Int) -> Int? {
        positionByNum[num]
    }

    /// The parsed body of a post, or empty content when it has not been indexed.
    public func content(of num: Int) -> PostContent {
        index.content(of: num) ?? .empty
    }

    public func isDeleted(_ num: Int) -> Bool {
        deletedPostNums.contains(num)
    }

    public func isOwn(_ num: Int) -> Bool {
        ownPostNums.contains(num)
    }

    /// True when the post replies to something the reader wrote, which the view
    /// marks so replies are easy to spot.
    public func repliesToOwnPost(_ num: Int) -> Bool {
        guard !ownPostNums.isEmpty else { return false }
        return index.references(from: num).contains { ownPostNums.contains($0) }
    }

    /// Posts matching a search, in reading order.
    ///
    /// Searches the rendered text rather than the raw comment, so a query such
    /// as "span" matches what the reader can see and not the markup behind it.
    /// A query that is only digits also matches post numbers, which is how
    /// readers look for a post they were linked to.
    public func posts(matching query: String) -> [Post] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return posts }

        let numericQuery = Int(trimmed)
        return posts.filter { post in
            if let numericQuery, String(post.num).contains(String(numericQuery)) {
                return true
            }
            if post.subject.localizedCaseInsensitiveContains(trimmed) { return true }
            if post.name.localizedCaseInsensitiveContains(trimmed) { return true }
            if post.files.contains(where: {
                $0.fullName.localizedCaseInsensitiveContains(trimmed)
            }) {
                return true
            }
            return content(of: post.num).plainText.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Every attachment in the thread, in post order. Backs the gallery.
    public var allAttachments: [(post: Post, attachment: Attachment)] {
        posts.flatMap { post in post.files.map { (post, $0) } }
    }
}

/// Thread-level facts that are not about any single post.
public struct ThreadMeta: Sendable, Equatable {
    public var title: String
    public var postsCount: Int
    public var filesCount: Int
    public var uniquePosters: Int
    /// Highest post number seen; the anchor for the next incremental refresh.
    public var maxNum: Int
    public var isClosed: Bool
    /// A cycling thread, which drops its oldest posts rather than hitting a limit.
    public var isEndless: Bool
    public var isSticky: Bool
    /// The thread 404s: it was deleted or archived away.
    public var isDeleted: Bool
    /// Board settings, when the response carried them.
    public var board: Board?

    public init(
        title: String = "",
        postsCount: Int = 0,
        filesCount: Int = 0,
        uniquePosters: Int = 0,
        maxNum: Int = 0,
        isClosed: Bool = false,
        isEndless: Bool = false,
        isSticky: Bool = false,
        isDeleted: Bool = false,
        board: Board? = nil
    ) {
        self.title = title
        self.postsCount = postsCount
        self.filesCount = filesCount
        self.uniquePosters = uniquePosters
        self.maxNum = maxNum
        self.isClosed = isClosed
        self.isEndless = isEndless
        self.isSticky = isSticky
        self.isDeleted = isDeleted
        self.board = board
    }

    public static let empty = ThreadMeta()

    /// Builds the metadata from a full thread response.
    public init(response: ThreadResponse) {
        let op = response.posts.first
        self.init(
            title: response.title,
            postsCount: response.postsCount,
            filesCount: response.filesCount,
            uniquePosters: response.uniquePosters,
            maxNum: response.maxNum,
            isClosed: response.isClosed || (op?.isClosed ?? false),
            isEndless: op?.isEndless ?? false,
            isSticky: op?.isSticky ?? false,
            isDeleted: false,
            board: response.board
        )
    }
}

/// What a thread load produced.
public enum ThreadUpdate: Sendable {
    /// The list was rebuilt; re-render everything.
    case replaced(ThreadSnapshot)
    /// Posts were added. The numbers are the new ones, for the unread divider.
    case appended(ThreadSnapshot, newPostNums: [Int])
    /// Only thread-level facts changed, for example the thread closed.
    case metaChanged(ThreadSnapshot)
    /// A refresh failed. The snapshot is the last good one.
    case failed(ThreadSnapshot, error: DvachError)
}
