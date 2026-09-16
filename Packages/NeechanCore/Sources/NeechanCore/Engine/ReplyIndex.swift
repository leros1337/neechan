import Foundation
import NeechanAPI

/// Who replied to whom, within one thread.
///
/// Built once when a thread loads and extended as posts arrive, because
/// re-parsing every comment on each refresh is the most expensive thing the
/// thread view could do. The parsed bodies are kept here too, so the view never
/// parses HTML while scrolling.
public struct ReplyIndex: Sendable {
    private let thread: ThreadKey
    private let parser = CommentHTMLParser()

    /// Post number to the numbers of posts replying to it, in arrival order.
    private var incoming: [Int: [Int]] = [:]
    /// Post number to the in-thread posts it replies to.
    private var outgoing: [Int: [Int]] = [:]
    /// Parsed comment bodies, keyed by post number.
    private var parsed: [Int: PostContent] = [:]

    public init(posts: [Post] = [], thread: ThreadKey) {
        self.thread = thread
        append(posts)
    }

    /// Numbers of the posts replying to `num`.
    public func backlinks(to num: Int) -> [Int] {
        incoming[num] ?? []
    }

    /// In-thread posts that `num` replies to.
    public func references(from num: Int) -> [Int] {
        outgoing[num] ?? []
    }

    /// The parsed body of `num`, if it has been indexed.
    public func content(of num: Int) -> PostContent? {
        parsed[num]
    }

    public func hasContent(for num: Int) -> Bool {
        parsed[num] != nil
    }

    /// Indexes more posts. Posts already indexed are re-indexed in place, which
    /// is what an edited or newly banned post needs.
    public mutating func append(_ posts: [Post]) {
        for post in posts {
            let content = parser.parse(
                post.comment,
                inThread: thread.threadNum,
                onBoard: thread.board
            )
            parsed[post.num] = content

            // Only links inside this thread become backlinks; a cross-thread
            // reference is still shown, but it belongs to another thread's index.
            var targets: [Int] = []
            for reference in content.references
            where reference.isSameThread && reference.postNum != post.num {
                if !targets.contains(reference.postNum) {
                    targets.append(reference.postNum)
                }
            }
            outgoing[post.num] = targets

            for target in targets {
                var replies = incoming[target] ?? []
                if !replies.contains(post.num) {
                    replies.append(post.num)
                    incoming[target] = replies
                }
            }
        }
    }

    /// Posts replying, directly or transitively, to `num`. Backs "hide the
    /// replies tree" and the replies sheet.
    public func repliesTree(from num: Int) -> Set<Int> {
        var found: Set<Int> = []
        var queue = backlinks(to: num)
        while let next = queue.popLast() {
            guard found.insert(next).inserted else { continue }
            queue.append(contentsOf: backlinks(to: next))
        }
        return found
    }

    /// Posts that reply to any of `nums`. Backs "replies to my posts".
    public func replies(toAnyOf nums: Set<Int>) -> Set<Int> {
        var found: Set<Int> = []
        for num in nums {
            found.formUnion(backlinks(to: num))
        }
        return found
    }
}
