import Foundation
import SwiftUI

/// Marks what a thread search found in a rendered post body.
///
/// Applied on top of the body `PostBodyCache` hands back rather than inside the
/// renderer, so a search neither re-renders the thread nor multiplies the
/// cache's entries by every query typed.
enum SearchHighlighter {
    enum Style {
        /// The post the reader stepped to.
        case current
        /// Every other post the search found.
        case other

        /// Pale yellow for every hit and orange for the one the reader is on,
        /// the way a browser's find bar marks them. Two strengths of the same
        /// yellow were tried first and could not be told apart on a dark theme.
        var color: Color {
            switch self {
            case .current: Color.orange.opacity(0.85)
            case .other: Color.yellow.opacity(0.3)
            }
        }
    }

    /// The text with every occurrence of the query marked.
    ///
    /// Matched by `SearchText`, the same way the thread counts its matches, so
    /// the hits marked here are the hits the counter steps through. A hidden
    /// spoiler is left alone: a search must not be a way round one.
    ///
    /// - Parameter current: which occurrence the reader is on, marked more
    ///   strongly than the rest. Nil when this post is not the current match.
    static func highlight(
        _ text: AttributedString,
        query: String,
        current: Int? = nil
    ) -> AttributedString {
        let plain = String(text.characters)
        let found = SearchText.ranges(of: query, in: plain)
        guard !found.isEmpty else { return text }

        var result = text
        for (index, range) in found.enumerated() {
            let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: range.upperBound)
            let start = result.characters.index(result.startIndex, offsetBy: lower)
            let end = result.characters.index(result.startIndex, offsetBy: upper)
            let style: Style = index == current ? .current : .other
            mark(start..<end, in: &result, color: style.color)
        }
        return result
    }

    /// The body up to the end of one occurrence, for measuring how far down
    /// the post it sits.
    static func prefix(
        _ text: AttributedString,
        throughOccurrence occurrence: Int,
        of query: String
    ) -> AttributedString? {
        let plain = String(text.characters)
        let found = SearchText.ranges(of: query, in: plain)
        guard found.indices.contains(occurrence) else { return nil }
        let upper = plain.distance(from: plain.startIndex, to: found[occurrence].upperBound)
        let end = text.characters.index(text.startIndex, offsetBy: upper)
        return AttributedString(text[text.startIndex..<end])
    }

    /// Colours one match, skipping whatever part of it is a hidden spoiler.
    private static func mark(
        _ range: Range<AttributedString.Index>,
        in text: inout AttributedString,
        color: Color
    ) {
        for run in text[range].runs where !isHiddenSpoiler(run.link) {
            text[run.range].backgroundColor = color
        }
    }

    /// A hidden spoiler is the only thing drawn with the reveal link.
    private static func isHiddenSpoiler(_ link: URL?) -> Bool {
        guard let link else { return false }
        if case .toggleSpoilers = NeechanURL.action(for: link) { return true }
        return false
    }
}

/// Where a query occurs in a piece of text.
///
/// The one definition of a hit, shared by the counter and the highlighter.
/// Case-insensitive the way `localizedCaseInsensitiveContains` is, which is how
/// the snapshot decides a post matches at all: a looser rule here would mark
/// hits in posts the search never found.
enum SearchText {
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var found: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(
            of: needle,
            options: .caseInsensitive,
            range: searchRange,
            locale: .current
        ), !range.isEmpty {
            found.append(range)
            searchRange = range.upperBound..<text.endIndex
        }
        return found
    }
}
