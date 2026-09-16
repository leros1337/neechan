import Foundation

/// Whether a post is long enough to be worth measuring for truncation.
///
/// SwiftUI does not report whether a line limit cut anything off, so the only
/// way to know is to lay the text out twice: once as drawn, once unconstrained.
/// Most posts on a board are a line or two and could not possibly be cut off, so
/// this answers for them from the text alone and the second layout is skipped.
enum CollapsePolicy {
    /// The fewest characters a line of a post body can hold.
    ///
    /// Deliberately pessimistic. The body is Dynamic Type at the reader's own
    /// scale on top, so at the largest accessibility size and a doubled scale a
    /// narrow phone still fits about eleven characters; eight leaves room.
    private static let minimumCharactersPerLine = 8

    /// Whether `limit` lines could cut this post off.
    ///
    /// Only ever wrong in the safe direction: a true answer means "measure it",
    /// not "it is truncated". Returning false for a post that could be cut off
    /// would lose the reader the control to expand it, so the line estimate is
    /// an upper bound — every hard line break starts a line, and the text on top
    /// of them wraps at worst every `minimumCharactersPerLine` characters.
    static func mayTruncate(lineBreaks: Int, characters: Int, limit: Int) -> Bool {
        guard limit > 0 else { return false }
        let hardLines = lineBreaks + 1
        let wrappedLines =
            (characters + minimumCharactersPerLine - 1) / minimumCharactersPerLine
        return hardLines + wrappedLines > limit
    }
}
