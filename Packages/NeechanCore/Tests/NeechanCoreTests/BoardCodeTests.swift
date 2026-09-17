import Testing
@testable import NeechanCore

/// What a reader may type where a board code is wanted.
@Suite("Board code")
struct BoardCodeTests {
    @Test(
        "the ways a board is written all read as the same code",
        arguments: ["b", "/b/", " B ", "  /B/  ", "b/", "/b"]
    )
    func spellings(input: String) {
        #expect(BoardCode.normalized(input) == "b")
    }

    /// A keyboard, or a paste, adds more than spaces.
    @Test("tabs and newlines are not part of the code")
    func whitespace() {
        #expect(BoardCode.normalized("\tb\n") == "b")
        #expect(BoardCode.normalized("\n /po/ \t") == "po")
    }

    @Test("a longer code survives, with its digits")
    func longerCodes() {
        #expect(BoardCode.normalized("vg") == "vg")
        #expect(BoardCode.normalized("2ch") == "2ch")
    }

    @Test(
        "what cannot be a board code is nothing at all",
        arguments: [
            "",
            "   ",
            "/",
            "//",
            "hello world",
            "b/vg",
            "12345",
            "б",
            "toolongboardcode",
        ]
    )
    func rejected(input: String) {
        #expect(BoardCode.normalized(input) == nil)
    }

    /// Digits alone are a post number, which is why a code needs a letter.
    @Test("a number is not a board")
    func numbersAreNotBoards() {
        #expect(BoardCode.normalized("336654150") == nil)
    }

    @Test("a code already in its plain form is valid")
    func validity() {
        #expect(BoardCode.isValid("b"))
        #expect(BoardCode.isValid("/b/") == false)
        #expect(BoardCode.isValid("hello world") == false)
    }

    // MARK: Two imageboards

    /// 4chan has `/3/`, and a board code that is all digits used to be refused
    /// outright because a bare post number looks exactly like one.
    @Test("an all-digit board code is accepted only where such a board exists")
    func numericBoardCodes() {
        #expect(BoardCode.normalized("3", for: .fourchan) == "3")
        #expect(BoardCode.normalized("/3/", for: .fourchan) == "3")
        #expect(BoardCode.normalized("3", for: .dvach) == nil)
    }

    /// The reason the rule exists in the first place.
    @Test("a post number is still not a board, even where digits are allowed")
    func postNumbersAreNotBoards() {
        #expect(BoardCode.normalized("336654150", for: .fourchan) == nil)
        #expect(BoardCode.normalized("123", for: .fourchan) == nil)
    }

    @Test("4chan's ordinary board codes are unremarkable")
    func fourchanCodes() {
        for code in ["g", "po", "vg", "lgbt", "trash", "wsr"] {
            #expect(BoardCode.normalized(code, for: .fourchan) == code)
        }
    }
}
