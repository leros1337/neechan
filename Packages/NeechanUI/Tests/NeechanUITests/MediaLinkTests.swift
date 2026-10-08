import Foundation
import NeechanAPI
import NeechanCore
import NeechanMedia
import Testing
@testable import NeechanUI

/// Which links in a post the viewer opens, and where it fetches them from.
///
/// The regression: a link straight to a file — a clip on another 2ch mirror,
/// most often — went to the browser like any page, so a reader tapped a
/// `.mp4` and got a Safari sheet instead of the app's own player.
@Suite("A link in a post to a picture or a clip")
struct MediaLinkTests {
    private func link(_ address: String, on site: Imageboard = .dvach) throws -> MediaLink? {
        MediaLink(url: try #require(URL(string: address)), readingOn: site)
    }

    private func item(_ link: MediaLink, site: Imageboard = .dvach) -> GalleryItem {
        GalleryItem(
            attachment: link.attachment,
            postNum: 1,
            threadKey: ThreadKey(site: site, board: "test", threadNum: 1)
        )
    }

    // MARK: The imageboard's own files

    /// The link that was reported: a clip on 2ch.su, read with another
    /// mirror selected.
    @Test("a clip on a 2ch mirror plays from the mirror the app is set to")
    func clipOnAnotherMirror() throws {
        let found = try #require(
            try link("https://2ch.su/test/src/237957/17847495108690174855.mp4")
        )

        #expect(found.attachment.path == "/test/src/237957/17847495108690174855.mp4")
        #expect(found.attachment.name == "17847495108690174855.mp4")
        #expect(found.board == BoardRef(site: .dvach, code: "test"))
        #expect(item(found).fileURL(mirror: .org)?.host() == "2ch.org")
        #expect(item(found).kind == .mp4Video)
    }

    /// Mirrors the app does not talk to are still 2ch's, and are the ones
    /// most worth rewriting: they are the ones that go dark.
    @Test(
        "every 2ch host is read as the selected mirror",
        arguments: [
            "https://2ch.hk/b/src/1/2.webm",
            "https://2ch.pm/b/src/1/2.webm",
            "https://www.2ch.life/b/src/1/2.webm",
            "https://2ch.org/b/src/1/2.webm",
            "http://2ch.su/b/src/1/2.webm",
        ]
    )
    func everyMirror(address: String) throws {
        let found = try #require(try link(address))

        #expect(found.attachment.path == "/b/src/1/2.webm")
        #expect(found.board == BoardRef(site: .dvach, code: "b"))
        #expect(item(found).kind == .webmVideo)
    }

    /// A link with no host is the site's own, and used to reach the Safari
    /// sheet with no scheme at all.
    @Test("a link with no host is a file on the site being read")
    func rootRelative() throws {
        let found = try #require(try link("/b/src/1/2.webm"))

        #expect(found.attachment.path == "/b/src/1/2.webm")
        #expect(found.board == BoardRef(site: .dvach, code: "b"))
    }

    @Test(
        "pictures open too",
        arguments: [
            ("https://2ch.su/a/src/1/2.jpg", MediaKind.stillImage),
            ("https://2ch.su/a/src/1/2.png", MediaKind.stillImage),
            ("https://2ch.su/a/src/1/2.webp", MediaKind.stillImage),
            ("https://2ch.su/a/src/1/2.gif", MediaKind.animatedImage),
        ]
    )
    func pictures(address: String, kind: MediaKind) throws {
        let found = try #require(try link(address))
        #expect(item(found).kind == kind)
    }

    @Test("the extension is read whatever its case")
    func uppercaseExtension() throws {
        let found = try #require(try link("https://2ch.su/b/src/1/2.MP4"))
        #expect(item(found).kind == .mp4Video)
    }

    /// 4chan's files live on a host of their own, which is still 4chan's.
    @Test("a 4chan file read on 4chan is 4chan's, on its own media host")
    func fourchanMedia() throws {
        let found = try #require(try link("https://i.4cdn.org/g/1700000000000.webm", on: .fourchan))

        #expect(found.attachment.path == "https://i.4cdn.org/g/1700000000000.webm")
        #expect(found.board == BoardRef(site: .fourchan, code: "g"))
        #expect(item(found, site: .fourchan).kind == .webmVideo)
    }

    /// The selected mirror is a 2ch setting, so it means nothing for a file
    /// linked from a thread on the other site: that file stays where it is.
    @Test("a 2ch file linked from a 4chan thread keeps its own host")
    func otherSitesFile() throws {
        let found = try #require(try link("https://2ch.su/b/src/1/2.mp4", on: .fourchan))

        #expect(found.attachment.path == "https://2ch.su/b/src/1/2.mp4")
        #expect(found.board == BoardRef(site: .dvach, code: "b"))
    }

    // MARK: Files anywhere else

    @Test("a clip on a file host plays from that host")
    func foreignHost() throws {
        let found = try #require(try link("https://files.catbox.moe/abc123.webm"))

        #expect(found.attachment.path == "https://files.catbox.moe/abc123.webm")
        #expect(found.board == nil)
        #expect(item(found).fileURL(mirror: .org) == URL(string: "https://files.catbox.moe/abc123.webm"))
        #expect(item(found).kind == .webmVideo)
    }

    /// Discord signs its links with a query, which sits after the extension
    /// and must not hide it.
    @Test("a query after the extension does not hide what the file is")
    func signedLink() throws {
        let address = "https://cdn.discordapp.com/attachments/1/2/clip.mp4?ex=6a&is=6b&hm=ff"
        let found = try #require(try link(address))

        #expect(found.attachment.path == address)
        #expect(found.attachment.name == "clip.mp4")
        #expect(item(found).kind == .mp4Video)
    }

    @Test("a .mov plays as the video it is")
    func quickTime() throws {
        let found = try #require(try link("https://example.com/v/clip.mov?dl=1"))
        #expect(item(found).kind == .mp4Video)
    }

    // MARK: Not files

    @Test(
        "anything that is not a picture or a clip is left alone",
        arguments: [
            "https://2ch.su/b/res/1.html",
            "https://2ch.su/b/res/1.html#2",
            "https://2ch.su/b/",
            "https://example.com/page",
            "https://example.com/",
            "https://example.com/archive.zip",
            "https://example.com/song.mp3",
            "mailto:someone@example.com",
            "ftp://example.com/clip.mp4",
            "magnet:?xt=urn:btih:abc&dn=clip.mp4",
        ]
    )
    func notFiles(address: String) throws {
        #expect(try link(address) == nil)
    }

    // MARK: Who may open it

    private let adult = ContentPolicy(allowsMatureBoards: true, listsEveryBoard: true)
    private let underage = ContentPolicy(allowsMatureBoards: false, listsEveryBoard: true)

    @Test("a file on a board the reader may open is opened")
    func allowedBoard() throws {
        let found = try #require(try link("https://2ch.su/a/src/1/2.mp4"))
        #expect(found.isAllowed(by: underage))
        #expect(found.isAllowed(by: adult))
    }

    /// The viewer is a surface the app answers for, so it refuses what the
    /// board itself would refuse; the link then goes out the way it did.
    @Test("a file on a board for adults is refused until the reader says they are 18")
    func restrictedBoard() throws {
        let found = try #require(try link("https://2ch.su/b/src/1/2.mp4"))
        #expect(!found.isAllowed(by: underage))
        #expect(found.isAllowed(by: adult))
    }

    /// The same rule the in-app browser follows: a stranger's link to
    /// anywhere at all is shown in the app only once the reader is 18.
    @Test("a file anywhere else is refused until the reader says they are 18")
    func foreignHostPolicy() throws {
        let found = try #require(try link("https://files.catbox.moe/abc123.webm"))
        #expect(!found.isAllowed(by: underage))
        #expect(found.isAllowed(by: adult))
    }
}

/// Opening the viewer on a file a post links to.
@Suite("The viewer opened from a link")
struct LinkedFileGalleryTests {
    private let key = ThreadKey(site: .dvach, board: "test", threadNum: 100)
    private let adult = ContentPolicy(allowsMatureBoards: true, listsEveryBoard: true)

    private func snapshot(_ posts: [Post]) -> ThreadSnapshot {
        ThreadSnapshot(
            key: key,
            posts: posts,
            meta: .empty,
            index: ReplyIndex(posts: posts, thread: key)
        )
    }

    private func post(_ num: Int, linking address: String? = nil) -> Post {
        let comment = address.map { #"look <a href="\#($0)" target="_blank" rel="nofollow noopener noreferrer">\#($0)</a>"# }
        return Post(
            num: num,
            parent: num == key.threadNum ? 0 : key.threadNum,
            board: key.board,
            comment: comment ?? "nothing here"
        )
    }

    @Test("the file is filed under the post that links to it")
    func findsThePost() throws {
        let address = "https://2ch.su/test/src/237957/17847495108690174855.mp4"
        let thread = snapshot([post(100), post(101), post(102, linking: address), post(103)])

        let url = try #require(URL(string: address))

        let start = try #require(thread.galleryStart(forLink: url, policy: adult))

        #expect(start.index == 0)
        #expect(start.items.count == 1)
        let item = try #require(start.items.first)
        #expect(item.postNum == 102)
        #expect(item.threadKey == key)
        #expect(item.attachment.path == "/test/src/237957/17847495108690174855.mp4")
    }

    /// A link tapped in a quote fetched from another thread is in no post
    /// here; the file still opens, filed under this thread.
    @Test("a link no post here carries is filed under the opening post")
    func fallsBackToTheThread() throws {
        let thread = snapshot([post(100), post(101)])
        let url = try #require(URL(string: "https://2ch.su/test/src/1/2.webm"))

        let start = try #require(thread.galleryStart(forLink: url, policy: adult))

        #expect(start.items.first?.postNum == 100)
    }

    @Test("a link to a page opens no viewer")
    func pageLink() throws {
        let address = "https://example.com/page"
        let thread = snapshot([post(100, linking: address)])
        let url = try #require(URL(string: address))

        #expect(thread.galleryStart(forLink: url, policy: adult) == nil)
    }

    @Test("a refused file opens no viewer")
    func refused() throws {
        let address = "https://2ch.su/b/src/1/2.mp4"
        let thread = snapshot([post(100, linking: address)])
        let underage = ContentPolicy(allowsMatureBoards: false, listsEveryBoard: true)
        let url = try #require(URL(string: address))

        #expect(thread.galleryStart(forLink: url, policy: underage) == nil)
    }
}
