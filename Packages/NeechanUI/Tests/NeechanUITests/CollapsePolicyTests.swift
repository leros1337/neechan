import Foundation
import Testing
@testable import NeechanUI

@Suite("Collapse policy")
struct CollapsePolicyTests {
    @Test("a one-line post cannot be cut off")
    func shortPost() {
        #expect(CollapsePolicy.mayTruncate(lineBreaks: 0, characters: 4, limit: 12) == false)
    }

    @Test("a post with fewer hard lines than the limit and little text cannot be cut off")
    func shortMultiLinePost() {
        #expect(CollapsePolicy.mayTruncate(lineBreaks: 2, characters: 15, limit: 12) == false)
    }

    @Test("one very long line can be cut off, because it wraps")
    func longSingleLine() {
        #expect(CollapsePolicy.mayTruncate(lineBreaks: 0, characters: 2000, limit: 12))
    }

    @Test("more hard line breaks than the limit can always be cut off")
    func manyLineBreaks() {
        #expect(CollapsePolicy.mayTruncate(lineBreaks: 20, characters: 40, limit: 12))
    }

    /// The estimate must never claim a post is safe when it is not, so it counts
    /// the fewest characters a line could hold rather than the most.
    @Test("the estimate errs towards measuring")
    func estimateIsConservative() {
        // Twelve lines of eight characters exactly fills a twelve-line limit at
        // the narrowest a line can be, so it has to be measured.
        #expect(CollapsePolicy.mayTruncate(lineBreaks: 11, characters: 96, limit: 12))
    }

    @Test("a limit of zero means nothing is ever collapsed")
    func noLimit() {
        #expect(CollapsePolicy.mayTruncate(lineBreaks: 99, characters: 9999, limit: 0) == false)
    }
}
