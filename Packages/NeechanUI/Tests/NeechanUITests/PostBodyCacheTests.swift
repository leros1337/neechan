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
        palette: PostTextRenderer.Palette = .init()
    ) -> PostTextRenderer.Options {
        .init(postNum: postNum, revealSpoilers: revealSpoilers, palette: palette)
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
