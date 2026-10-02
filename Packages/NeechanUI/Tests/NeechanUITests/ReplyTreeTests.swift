import Foundation
import NeechanAPI
import NeechanCore
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// What the replies window lists, and what each card in it offers.
///
/// The regression: a reply shown in the window never said it had replies of
/// its own. The thread's posts carry an "N replies" button; inside the window
/// every card was built with none, so a reader following a conversation had
/// nowhere to go past the first level except by finding a quote to tap.
@Suite("Replies in the replies window")
struct ReplyTreeTests {
    private func snapshot() throws -> ThreadSnapshot {
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let key = ThreadKey(site: .dvach, board: "po", threadNum: response.currentThread)
        return ThreadSnapshot(
            key: key,
            posts: response.posts,
            meta: ThreadMeta(response: response),
            index: ReplyIndex(posts: response.posts, thread: key)
        )
    }

    /// A post whose replies include one that is replied to in turn.
    private func chain(in snapshot: ThreadSnapshot) throws -> (post: Int, reply: Int, replyToReply: Int) {
        for post in snapshot.posts {
            for reply in snapshot.index.backlinks(to: post.num) {
                if let deeper = snapshot.index.backlinks(to: reply).first {
                    return (post.num, reply, deeper)
                }
            }
        }
        Issue.record("the fixture holds no reply that is replied to")
        throw CancellationError()
    }

    @Test("a post's replies are the posts that answer it, in thread order")
    func replies() throws {
        let snapshot = try snapshot()
        let (post, _, _) = try chain(in: snapshot)
        let tree = ReplyTree(snapshot: snapshot, hidden: [])

        let nums = tree.replies(to: post).map(\.num)
        #expect(nums == snapshot.index.backlinks(to: post))
        #expect(nums == nums.sorted(), "replies came out of thread order")
    }

    @Test("a reply that is answered in turn says so, so its card can offer the way on")
    func repliesToAReply() throws {
        let snapshot = try snapshot()
        let (_, reply, replyToReply) = try chain(in: snapshot)
        let tree = ReplyTree(snapshot: snapshot, hidden: [])

        #expect(tree.replyNums(to: reply).contains(replyToReply))
        #expect(tree.replyNums(to: reply) == tree.replies(to: reply).map(\.num))
    }

    /// The button's count and the list it opens are one answer, so a hidden
    /// reply cannot make the one say three and the other show two.
    @Test("a hidden reply is left out of the count and the list alike")
    func hiddenRepliesLeftOut() throws {
        let snapshot = try snapshot()
        let (post, reply, _) = try chain(in: snapshot)
        let tree = ReplyTree(snapshot: snapshot, hidden: [reply])

        #expect(!tree.replyNums(to: post).contains(reply))
        #expect(!tree.replies(to: post).map(\.num).contains(reply))
        #expect(tree.replyNums(to: post).count == tree.replies(to: post).count)
    }
}
