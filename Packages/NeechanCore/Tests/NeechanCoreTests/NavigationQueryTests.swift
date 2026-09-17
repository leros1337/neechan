import Foundation
import NeechanAPI
import Testing
@testable import NeechanCore

@Suite("Navigation query parser")
struct NavigationQueryTests {
    private func parse(
        _ text: String,
        site: Imageboard = .dvach,
        currentBoard: String? = nil
    ) -> NavigationTarget? {
        NavigationQueryParser.parse(text, site: site, currentBoard: currentBoard)
    }

    private func board(_ code: String, _ site: Imageboard = .dvach) -> NavigationTarget {
        .board(BoardRef(site: site, code: code))
    }

    private func thread(_ code: String, _ num: Int, _ site: Imageboard = .dvach) -> NavigationTarget {
        .thread(ThreadKey(site: site, board: code, threadNum: num))
    }

    // MARK: Board codes

    @Test("a bare board code opens that board")
    func bareBoardCode() {
        #expect(parse("b") == board("b"))
        #expect(parse("vg") == board("vg"))
    }

    @Test("a board code written with slashes opens that board")
    func slashedBoardCode() {
        #expect(parse("/b/") == board("b"))
        #expect(parse("/po/") == board("po"))
        #expect(parse("/b") == board("b"))
    }

    @Test("surrounding whitespace and case are ignored")
    func normalisesInput() {
        #expect(parse("  /B/  ") == board("b"))
    }

    // MARK: Post numbers

    @Test("a bare number is a post in the board being read")
    func bareNumberInContext() {
        #expect(parse("123456", currentBoard: "b") == .post(BoardRef(site: .dvach, code: "b"), num: 123456))
    }

    @Test("a bare number with no board in context cannot be resolved")
    func bareNumberWithoutContext() {
        #expect(parse("123456") == nil)
    }

    @Test("a number written as a quote is still a post")
    func quotedNumber() {
        #expect(parse(">>123456", currentBoard: "b") == .post(BoardRef(site: .dvach, code: "b"), num: 123456))
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
        #expect(parse(link) == thread("b", 123))
    }

    @Test("a link with a post anchor opens the thread at that post")
    func threadLinkWithAnchor() {
        #expect(
            parse("https://2ch.org/b/res/123.html#456")
                == .threadAtPost(ThreadKey(site: .dvach, board: "b", threadNum: 123), postNum: 456)
        )
    }

    @Test("a board link opens the board")
    func boardLink() {
        #expect(parse("https://2ch.org/vg/") == board("vg"))
        #expect(parse("https://2ch.org/vg/index.html") == board("vg"))
        #expect(parse("https://2ch.org/vg/catalog.html") == board("vg"))
    }

    @Test("a link to a site the app does not know is not a destination")
    func foreignLink() {
        #expect(parse("https://example.com/b/res/123.html") == nil)
    }

    // MARK: Two imageboards

    @Test("a 4chan thread link opens on 4chan, whatever site is selected", arguments: [
        "https://boards.4chan.org/g/thread/123",
        "https://boards.4chan.org/g/thread/123/some-slug",
        "https://4chan.org/g/thread/123",
    ])
    func fourchanThreadLinks(_ link: String) {
        // The host names the imageboard; the selected one does not get a vote.
        #expect(parse(link, site: .dvach) == thread("g", 123, .fourchan))
    }

    @Test("4chan anchors a post with a p, and it still resolves")
    func fourchanAnchor() {
        #expect(
            parse("https://boards.4chan.org/g/thread/123#p456")
                == .threadAtPost(ThreadKey(site: .fourchan, board: "g", threadNum: 123), postNum: 456)
        )
    }

    @Test("a 2ch link still opens on 2ch while 4chan is selected")
    func dvachLinkWhileOnFourchan() {
        #expect(parse("https://2ch.org/b/res/123.html", site: .fourchan) == thread("b", 123))
    }

    @Test("a path with no host is told apart by its own grammar")
    func pathOnlyGrammar() {
        // 2ch never writes `thread`, 4chan never writes `res`, so a bare path
        // resolves to whichever wrote it.
        #expect(parse("/g/thread/123", site: .dvach) == thread("g", 123, .fourchan))
        #expect(parse("/b/res/123.html", site: .fourchan) == thread("b", 123))
    }

    @Test("4chan's all-digit board is reachable by typing it")
    func numericBoardCode() {
        #expect(parse("3", site: .fourchan) == board("3", .fourchan))
        #expect(parse("/3/", site: .fourchan) == board("3", .fourchan))
        // On 2ch the same input is still a post number, not a board.
        #expect(parse("3", site: .dvach, currentBoard: "b")
            == .post(BoardRef(site: .dvach, code: "b"), num: 3))
    }

    @Test("a post number is not mistaken for 4chan's numeric board")
    func longNumberIsStillAPost() {
        #expect(parse("336654150", site: .fourchan, currentBoard: "g")
            == .post(BoardRef(site: .fourchan, code: "g"), num: 336654150))
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
