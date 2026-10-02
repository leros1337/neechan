import NeechanAPI
import NeechanCore

/// The replies to a post, as the replies window shows them.
///
/// One answer for both the list a card opens and the count on the card's
/// button, so the two cannot disagree about a hidden reply.
struct ReplyTree {
    let snapshot: ThreadSnapshot
    /// Posts a rule hides and the reader has not revealed.
    ///
    /// Hidden posts keep their place in the thread itself, as stubs, so a
    /// reply to one still makes sense. Here they are simply gone: the window is
    /// a list of replies, and a stub in it would be a row saying nothing.
    let hidden: Set<Int>

    /// The posts answering `postNum`, in thread order.
    func replies(to postNum: Int) -> [Post] {
        replyNums(to: postNum).compactMap { snapshot.post(num: $0) }
    }

    /// The same, as numbers, for a card's backlinks.
    func replyNums(to postNum: Int) -> [Int] {
        snapshot.index.backlinks(to: postNum)
            .filter { !hidden.contains($0) && snapshot.post(num: $0) != nil }
    }
}
