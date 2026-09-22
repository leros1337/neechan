import Foundation
import NeechanAPI
import SwiftUI
import Testing
@testable import NeechanUI

/// What was found is marked in the post, so the reader sees why it matched.
@Suite("Search highlighting")
struct SearchHighlighterTests {
    /// The highlighted stretches of a text, as the strings they cover.
    private func highlighted(_ text: AttributedString) -> [String] {
        text.runs
            .filter { $0.backgroundColor != nil }
            .map { String(text[$0.range].characters) }
    }

    @Test("every occurrence is marked, whatever its case")
    func marksEveryOccurrence() {
        let text = AttributedString("Кот спит. кот ест. КОТ.")

        let result = SearchHighlighter.highlight(text, query: "кот")

        #expect(highlighted(result) == ["Кот", "кот", "КОТ"])
    }

    /// The snapshot decides a post matches with a case-insensitive contains
    /// and nothing looser; marking more than that would light up hits in posts
    /// the counter never counted.
    @Test("hits are found exactly the way the thread's search finds posts")
    func matchesLikeTheSearch() {
        let text = "un café noir, CAFÉ"

        #expect(SearchText.ranges(of: "cafe", in: text).isEmpty)
        #expect(SearchText.ranges(of: "café", in: text).count == 2)
        #expect(text.localizedCaseInsensitiveContains("cafe") == false)
    }

    @Test("the space around a query is not part of it")
    func trimsTheQuery() {
        let text = AttributedString("a cat sat")

        let result = SearchHighlighter.highlight(text, query: "  cat ")

        #expect(highlighted(result) == ["cat"])
    }

    @Test("a query with nothing to find leaves the text alone")
    func noHitsLeavesTextUnchanged() {
        let text = AttributedString("nothing here")

        #expect(SearchHighlighter.highlight(text, query: "zzz") == text)
        #expect(SearchHighlighter.highlight(text, query: "   ") == text)
    }

    @Test("the occurrence the reader is on is marked more strongly than the rest")
    func currentIsDistinct() {
        let text = AttributedString("cat, cat, cat")

        let result = SearchHighlighter.highlight(text, query: "cat", current: 1)

        let colors = result.runs.compactMap(\.backgroundColor)
        #expect(colors == [
            SearchHighlighter.Style.other.color,
            SearchHighlighter.Style.current.color,
            SearchHighlighter.Style.other.color,
        ])
    }

    @Test("the body up to an occurrence ends with that occurrence")
    func prefixEndsAtTheOccurrence() {
        let text = AttributedString("one cat, two Cats, three")

        let prefix = SearchHighlighter.prefix(text, throughOccurrence: 1, of: "cat")

        #expect(prefix.map { String($0.characters) } == "one cat, two Cat")
        #expect(SearchHighlighter.prefix(text, throughOccurrence: 2, of: "cat") == nil)
    }

    /// A search must not be a way round a spoiler.
    @Test("a hidden spoiler is never uncovered")
    func skipsHiddenSpoilers() {
        var visible = AttributedString("cat and ")
        var spoiler = AttributedString("cat")
        spoiler.link = NeechanURL.spoilerToggle(postNum: 1)
        spoiler.backgroundColor = .black
        spoiler.foregroundColor = .black
        visible.append(spoiler)

        let result = SearchHighlighter.highlight(visible, query: "cat")

        let spoilerRun = result.runs.first { $0.link != nil }
        #expect(spoilerRun?.backgroundColor == .black)
        #expect(result.runs.first?.backgroundColor == SearchHighlighter.Style.other.color)
    }
}
