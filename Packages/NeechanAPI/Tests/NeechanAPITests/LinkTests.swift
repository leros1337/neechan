import Foundation
import Testing
@testable import NeechanAPI

@Suite("Shareable links")
struct SiteLinkTests {
    @Test("a board link matches the site's own address")
    func boardLink() throws {
        let url = try #require(SiteLinks.board("b", on: .init(site: .dvach, mirror: .org)))
        #expect(url.absoluteString == "https://2ch.org/b/")
    }

    @Test("a thread link points at the thread page")
    func threadLink() throws {
        let url = try #require(SiteLinks.thread(board: "b", threadNum: 123, on: .init(site: .dvach, mirror: .org)))
        #expect(url.absoluteString == "https://2ch.org/b/res/123.html")
    }

    @Test("a post link anchors on the post")
    func postLink() throws {
        let url = try #require(
            SiteLinks.post(board: "b", threadNum: 123, postNum: 456, on: .init(site: .dvach, mirror: .org))
        )
        #expect(url.absoluteString == "https://2ch.org/b/res/123.html#456")
    }

    @Test("the opening post needs no anchor")
    func openingPostLink() throws {
        let url = try #require(
            SiteLinks.post(board: "b", threadNum: 123, postNum: 123, on: .init(site: .dvach, mirror: .org))
        )
        #expect(url.absoluteString == "https://2ch.org/b/res/123.html")
    }

    @Test("links follow the selected mirror")
    func followsMirror() throws {
        let url = try #require(SiteLinks.thread(board: "po", threadNum: 7, on: .init(site: .dvach, mirror: .life)))
        #expect(url.absoluteString == "https://2ch.life/po/res/7.html")
    }

    @Test("a shared link parses back to the same destination")
    func roundTripsThroughTheParser() throws {
        // Anything the app hands out must be something it can also open.
        let url = try #require(
            SiteLinks.post(board: "b", threadNum: 123, postNum: 456, on: .init(site: .dvach, mirror: .org))
        )
        #expect(url.fragment() == "456")
        #expect(url.path().hasPrefix("/b/res/"))
    }
}

@Suite("Shareable links on 4chan")
struct FourchanLinkTests {
    private let fourchan = SiteSelection(site: .fourchan)

    @Test("a board link goes to the readable site, not the JSON host")
    func boardLink() throws {
        let url = try #require(SiteLinks.board("g", on: fourchan))
        #expect(url.absoluteString == "https://boards.4chan.org/g/")
    }

    @Test("a thread link uses 4chan's own path shape")
    func threadLink() throws {
        let url = try #require(SiteLinks.thread(board: "g", threadNum: 123, on: fourchan))
        #expect(url.absoluteString == "https://boards.4chan.org/g/thread/123")
    }

    @Test("a post link anchors with the p prefix 4chan uses")
    func postLink() throws {
        let url = try #require(
            SiteLinks.post(board: "g", threadNum: 123, postNum: 456, on: fourchan)
        )
        #expect(url.absoluteString == "https://boards.4chan.org/g/thread/123#p456")
    }

    @Test("the opening post needs no anchor here either")
    func openingPostLink() throws {
        let url = try #require(
            SiteLinks.post(board: "g", threadNum: 123, postNum: 123, on: fourchan)
        )
        #expect(url.absoluteString == "https://boards.4chan.org/g/thread/123")
    }
}
