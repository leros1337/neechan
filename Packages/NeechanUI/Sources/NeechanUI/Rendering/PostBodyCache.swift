import NeechanAPI
import SwiftUI

/// Rendered post bodies, kept between redraws.
///
/// Turning a parsed post into an `AttributedString` walks the whole tree and
/// coalesces a run per styled span, and it has to happen on the main actor
/// because the result carries `Color`s. A `LazyVStack` rebuilds a cell every
/// time it scrolls back into view, and any change to the thread rebuilds every
/// visible one, so the same handful of posts were re-rendered continuously
/// while reading. This turns all of those into a dictionary lookup.
@MainActor
final class PostBodyCache {
    static let shared = PostBodyCache()

    struct Key: Hashable {
        let board: String
        let postNum: Int
        let revealSpoilers: Bool
        let palette: PostTextRenderer.Palette
    }

    private struct Entry {
        /// Kept so a post that was re-indexed — edited, or newly marked banned
        /// — is spotted rather than served from before. The comparison is on
        /// the node tree, which is shared with the reply index and so usually
        /// settles on identical storage and costs nothing.
        let content: PostContent
        /// Which of this post's references were drawn with the reader's mark.
        ///
        /// Nothing in `Key` moves when the reader posts, so a body rendered
        /// before they replied would otherwise be served unmarked for as long as
        /// it survived eviction. Kept as the marked subset rather than the whole
        /// set of own posts, so posting in a thread only re-renders the handful
        /// of posts that quoted you rather than all of them.
        let markedRefs: Set<Int>
        /// Which of this post's references were drawn struck through.
        ///
        /// Kept for the same reason as `markedRefs`, and against the same
        /// failure: nothing in `Key` moves when the reader hides a post, so a
        /// body rendered before they hid it would be served un-struck for as
        /// long as it survived eviction. The struck subset rather than the
        /// whole hidden set, so hiding one post re-renders only the handful of
        /// posts that quoted it rather than the whole thread.
        let struckRefs: Set<Int>
        let text: AttributedString
        var usedAt: UInt64
    }

    private let capacity: Int
    private let render: (PostContent, PostTextRenderer.Options) -> AttributedString
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    /// - Parameters:
    ///   - capacity: how many rendered bodies to keep. A few screenfuls in
    ///     either direction; an `AttributedString` is a few times the size of
    ///     its text, so this is a megabyte or two at the top end.
    ///   - render: how to build one. Injected so a test can count the calls.
    init(
        capacity: Int = 256,
        render: @escaping (PostContent, PostTextRenderer.Options) -> AttributedString = {
            PostTextRenderer().render($0, options: $1)
        }
    ) {
        self.capacity = max(1, capacity)
        self.render = render
    }

    /// The rendered body for a post, rendering it only if it is not already in
    /// hand.
    func body(
        for content: PostContent,
        board: String,
        options: PostTextRenderer.Options
    ) -> AttributedString {
        let key = Key(
            board: board,
            postNum: options.postNum,
            revealSpoilers: options.revealSpoilers,
            palette: options.palette
        )
        clock &+= 1

        // Over the references parsed with the post, not over its tree.
        let markedRefs = Set(
            content.references.lazy.filter(options.marks).map(\.postNum)
        )
        let struckRefs = Set(
            content.references.lazy.filter(options.strikes).map(\.postNum)
        )

        if var hit = entries[key],
            hit.content == content,
            hit.markedRefs == markedRefs,
            hit.struckRefs == struckRefs {
            hit.usedAt = clock
            entries[key] = hit
            return hit.text
        }

        let text = render(content, options)
        entries[key] = Entry(
            content: content,
            markedRefs: markedRefs,
            struckRefs: struckRefs,
            text: text,
            usedAt: clock
        )
        evictIfNeeded()
        return text
    }

    /// Drops everything. Called when memory is short.
    func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    var count: Int { entries.count }

    /// Drops the least recently used quarter once the cache is over its size.
    ///
    /// In one pass rather than one entry at a time, so the cost of ordering the
    /// keys is paid once per quarter-capacity of misses instead of on every
    /// insertion.
    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let survivors = capacity - capacity / 4
        let doomed = entries
            .sorted { $0.value.usedAt < $1.value.usedAt }
            .prefix(entries.count - survivors)
        for (key, _) in doomed { entries.removeValue(forKey: key) }
    }
}
