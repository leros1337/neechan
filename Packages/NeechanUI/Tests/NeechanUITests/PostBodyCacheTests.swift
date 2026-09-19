import Foundation
import NeechanAPI
import Synchronization
import SwiftUI
import Testing
@testable import NeechanUI

@Suite("Post body cache")
@MainActor
struct PostBodyCacheTests {
    private func content(_ html: String) -> PostContent {
        CommentHTMLParser().parse(html, inThread: 100, onBoard: "b")
    }

    private func options(
        postNum: Int = 1,
        revealSpoilers: Bool = false,
        palette: PostTextRenderer.Palette = .init(),
        ownPostNums: Set<Int> = [],
        hiddenPostNums: Set<Int> = []
    ) -> PostTextRenderer.Options {
        .init(
            postNum: postNum,
            revealSpoilers: revealSpoilers,
            palette: palette,
            ownPostNums: ownPostNums,
            hiddenPostNums: hiddenPostNums
        )
    }

    /// Counts renders. Not a `var`: the cache's closure escapes.
    private final class Counter: @unchecked Sendable {
        private(set) var calls = 0
        func bump() { calls += 1 }
    }

    private func makeCache(capacity: Int = 256) -> (PostBodyCache, Counter) {
        let counter = Counter()
        let cache = PostBodyCache(capacity: capacity) { content, _ in
            counter.bump()
            return AttributedString(content.plainText)
        }
        return (cache, counter)
    }

    @Test("asking twice for the same post renders once")
    func hitsAreServedFromMemory() {
        let (cache, counter) = makeCache()
        let body = content("hello")

        let first = cache.body(for: body, board: "b", options: options())
        let second = cache.body(for: body, board: "b", options: options())

        #expect(counter.calls == 1)
        #expect(first == second)
    }

    /// The colours are baked into the text, so a theme change has to re-render.
    @Test("a different palette is rendered again")
    func paletteIsPartOfIdentity() {
        let (cache, counter) = makeCache()
        let body = content("hello")
        var other = PostTextRenderer.Palette()
        other.quote = .red

        _ = cache.body(for: body, board: "b", options: options())
        _ = cache.body(for: body, board: "b", options: options(palette: other))

        #expect(counter.calls == 2)
    }

    @Test("revealing a spoiler is rendered again")
    func spoilerStateIsPartOfIdentity() {
        let (cache, counter) = makeCache()
        let body = content("<span class=\"spoiler\">x</span>")

        _ = cache.body(for: body, board: "b", options: options())
        _ = cache.body(for: body, board: "b", options: options(revealSpoilers: true))

        #expect(counter.calls == 2)
    }

    /// A post can be re-indexed under the same number: edited, or newly marked
    /// banned. Serving the text from before would show the old post.
    @Test("a post whose content changed is rendered again")
    func changedContentIsNotServedFromMemory() {
        let (cache, counter) = makeCache()

        let first = cache.body(for: content("before"), board: "b", options: options())
        let second = cache.body(for: content("after"), board: "b", options: options())

        #expect(counter.calls == 2)
        #expect(first != second)
    }

    @Test("the same number on two boards is two posts")
    func boardIsPartOfIdentity() {
        let (cache, counter) = makeCache()
        let body = content("hello")

        _ = cache.body(for: body, board: "b", options: options())
        _ = cache.body(for: body, board: "po", options: options())

        #expect(counter.calls == 2)
    }

    /// A post read before the reader replied was rendered without its marker.
    /// Nothing in the key changes when they post, so without this the body from
    /// before would be served for as long as it survives eviction.
    @Test("a reference that became the reader's own is rendered again")
    func newlyOwnedReferenceIsRenderedAgain() {
        let (cache, counter) = makeCache()
        let body = content(Self.reply(to: 99))

        _ = cache.body(for: body, board: "b", options: options())
        _ = cache.body(for: body, board: "b", options: options(ownPostNums: [99]))

        #expect(counter.calls == 2)
    }

    @Test("the same marked reference twice still renders once")
    func markedReferenceIsStillCached() {
        let (cache, counter) = makeCache()
        let body = content(Self.reply(to: 99))

        _ = cache.body(for: body, board: "b", options: options(ownPostNums: [99]))
        _ = cache.body(for: body, board: "b", options: options(ownPostNums: [99]))

        #expect(counter.calls == 1)
    }

    /// Only the numbers this post actually points at can change how it draws.
    /// Keying on the whole set would re-render every post in the thread each
    /// time the reader posted.
    @Test("posting elsewhere in the thread does not re-render a post that never quoted you")
    func unrelatedOwnPostsDoNotInvalidate() {
        let (cache, counter) = makeCache()
        let body = content(Self.reply(to: 99))

        _ = cache.body(for: body, board: "b", options: options())
        _ = cache.body(for: body, board: "b", options: options(ownPostNums: [4321]))

        #expect(counter.calls == 1)
    }

    /// The same trap as the marker above, and the one the strikethrough would
    /// have walked into: nothing in the key moves when the reader hides a post,
    /// so the body from before would be served un-struck.
    @Test("a reference to a newly hidden post is rendered again")
    func newlyHiddenReferenceIsRenderedAgain() {
        let (cache, counter) = makeCache()
        let body = content(Self.reply(to: 99))

        _ = cache.body(for: body, board: "b", options: options())
        _ = cache.body(for: body, board: "b", options: options(hiddenPostNums: [99]))

        #expect(counter.calls == 2)
    }

    @Test("the same struck reference twice still renders once")
    func struckReferenceIsStillCached() {
        let (cache, counter) = makeCache()
        let body = content(Self.reply(to: 99))

        _ = cache.body(for: body, board: "b", options: options(hiddenPostNums: [99]))
        _ = cache.body(for: body, board: "b", options: options(hiddenPostNums: [99]))

        #expect(counter.calls == 1)
    }

    /// Hiding one post must not re-render the whole thread, which is why the
    /// cache keeps the struck subset rather than the hidden set.
    @Test("hiding a post does not re-render one that never quoted it")
    func unrelatedHiddenPostsDoNotInvalidate() {
        let (cache, counter) = makeCache()
        let body = content(Self.reply(to: 99))

        _ = cache.body(for: body, board: "b", options: options())
        _ = cache.body(for: body, board: "b", options: options(hiddenPostNums: [4321]))

        #expect(counter.calls == 1)
    }

    /// Revealing is the same move backwards, and just as easy to miss.
    @Test("revealing a hidden post renders the posts quoting it again")
    func revealedReferenceIsRenderedAgain() {
        let (cache, counter) = makeCache()
        let body = content(Self.reply(to: 99))

        _ = cache.body(for: body, board: "b", options: options(hiddenPostNums: [99]))
        _ = cache.body(for: body, board: "b", options: options())

        #expect(counter.calls == 2)
    }

    private static func reply(to postNum: Int) -> String {
        #"<a class="post-reply-link" data-thread="100" data-num="\#(postNum)">&gt;&gt;\#(postNum)</a>"#
    }

    @Test("the cache stays inside its capacity")
    func capacityIsHonoured() {
        let (cache, _) = makeCache(capacity: 8)

        for postNum in 1...40 {
            _ = cache.body(for: content("post \(postNum)"), board: "b", options: options(postNum: postNum))
        }

        #expect(cache.count <= 8)
    }

    @Test("what was used most recently survives eviction")
    func recentlyUsedSurvives() {
        let (cache, counter) = makeCache(capacity: 8)
        let kept = content("kept")

        _ = cache.body(for: kept, board: "b", options: options(postNum: 1))
        for postNum in 2...8 {
            _ = cache.body(for: content("post \(postNum)"), board: "b", options: options(postNum: postNum))
            // Touch the first one so it stays the most recently used.
            _ = cache.body(for: kept, board: "b", options: options(postNum: 1))
        }
        let before = counter.calls

        _ = cache.body(for: kept, board: "b", options: options(postNum: 1))

        #expect(counter.calls == before, "the post kept in use was not evicted")
    }
}
