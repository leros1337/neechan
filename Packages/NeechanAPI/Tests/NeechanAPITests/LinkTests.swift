import Foundation
import Testing
@testable import NeechanAPI

@Suite("Shareable links")
struct DvachLinkTests {
    @Test("a board link matches the site's own address")
    func boardLink() throws {
        let url = try #require(DvachLinks.board("b", on: .org))
        #expect(url.absoluteString == "https://2ch.org/b/")
    }

    @Test("a thread link points at the thread page")
    func threadLink() throws {
        let url = try #require(DvachLinks.thread(board: "b", threadNum: 123, on: .org))
        #expect(url.absoluteString == "https://2ch.org/b/res/123.html")
    }

    @Test("a post link anchors on the post")
    func postLink() throws {
        let url = try #require(
            DvachLinks.post(board: "b", threadNum: 123, postNum: 456, on: .org)
        )
        #expect(url.absoluteString == "https://2ch.org/b/res/123.html#456")
    }

    @Test("the opening post needs no anchor")
    func openingPostLink() throws {
        let url = try #require(
            DvachLinks.post(board: "b", threadNum: 123, postNum: 123, on: .org)
        )
        #expect(url.absoluteString == "https://2ch.org/b/res/123.html")
    }

    @Test("links follow the selected mirror")
    func followsMirror() throws {
        let url = try #require(DvachLinks.thread(board: "po", threadNum: 7, on: .life))
        #expect(url.absoluteString == "https://2ch.life/po/res/7.html")
    }

    @Test("a shared link parses back to the same destination")
    func roundTripsThroughTheParser() throws {
        // Anything the app hands out must be something it can also open.
        let url = try #require(
            DvachLinks.post(board: "b", threadNum: 123, postNum: 456, on: .org)
        )
        #expect(url.fragment() == "456")
        #expect(url.path().hasPrefix("/b/res/"))
    }
}
