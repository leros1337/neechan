import Foundation
import NeechanAPI
import Testing
@testable import NeechanCore

@Suite("Navigation query parser")
struct NavigationQueryTests {
    private func parse(_ text: String, currentBoard: String? = nil) -> NavigationTarget? {
        NavigationQueryParser.parse(text, currentBoard: currentBoard)
    }

    // MARK: Board codes

    @Test("a bare board code opens that board")
    func bareBoardCode() {
        #expect(parse("b") == .board(board: "b"))
        #expect(parse("vg") == .board(board: "vg"))
    }

    @Test("a board code written with slashes opens that board")
    func slashedBoardCode() {
        #expect(parse("/b/") == .board(board: "b"))
        #expect(parse("/po/") == .board(board: "po"))
        #expect(parse("/b") == .board(board: "b"))
    }

    @Test("surrounding whitespace and case are ignored")
    func normalisesInput() {
        #expect(parse("  /B/  ") == .board(board: "b"))
    }

    // MARK: Post numbers

    @Test("a bare number is a post in the board being read")
    func bareNumberInContext() {
        #expect(parse("123456", currentBoard: "b") == .post(board: "b", num: 123456))
    }

    @Test("a bare number with no board in context cannot be resolved")
    func bareNumberWithoutContext() {
        #expect(parse("123456") == nil)
    }

    @Test("a number written as a quote is still a post")
    func quotedNumber() {
        #expect(parse(">>123456", currentBoard: "b") == .post(board: "b", num: 123456))
    }

    // MARK: Links

    @Test("a thread link opens the thread", arguments: [
        "https://2ch.org/b/res/123.html",
        "https://2ch.life/b/res/123.html",
        "http://2ch.hk/b/res/123.html",
        "2ch.org/b/res/123.html",
        "/b/res/123.html",
    ])
    func threadLinks(_ link: String) {
        #expect(parse(link) == .thread(board: "b", threadNum: 123))
    }

    @Test("a link with a post anchor opens the thread at that post")
    func threadLinkWithAnchor() {
        #expect(
            parse("https://2ch.org/b/res/123.html#456")
                == .threadAtPost(board: "b", threadNum: 123, postNum: 456)
        )
    }

    @Test("a board link opens the board")
    func boardLink() {
        #expect(parse("https://2ch.org/vg/") == .board(board: "vg"))
        #expect(parse("https://2ch.org/vg/index.html") == .board(board: "vg"))
        #expect(parse("https://2ch.org/vg/catalog.html") == .board(board: "vg"))
    }

    @Test("a link to another site is not a 2ch destination")
    func foreignLink() {
        #expect(parse("https://example.com/b/res/123.html") == nil)
    }

    // MARK: Rejections

    @Test("empty input yields nothing")
    func emptyInput() {
        #expect(parse("") == nil)
        #expect(parse("   ") == nil)
    }

    @Test("free text is treated as a search term, not a destination")
    func freeText() {
        #expect(parse("что-то длинное для поиска") == nil)
        #expect(parse("нет такого") == nil)
    }

    @Test("a board code longer than the site uses is not a board")
    func overlongCode() {
        #expect(parse("abcdefghijklmnop") == nil)
    }

    @Test("a traversal attempt is not accepted as a board")
    func traversalIsRejected() {
        #expect(parse("../../etc") == nil)
        #expect(parse("/../") == nil)
    }
}
