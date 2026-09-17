import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanAPI

@Suite("4chan boards")
struct FourchanBoardTests {
    private func boards() throws -> [Board] {
        try FourchanMapping.boards(
            from: try FixtureLoader.data(.fourchanBoards),
            decoder: JSONDecoder()
        )
    }

    private func board(_ code: String) throws -> Board {
        try #require(try boards().first { $0.id == code })
    }

    /// The documentation says kilobytes and the server sends bytes. Asserted
    /// both ways, because the model stores one and the app reads the other.
    @Test("the upload limit survives the site reporting it in bytes")
    func fileSizeIsConverted() throws {
        let three = try board("3")
        #expect(three.maxFilesSizeKB == 4096)
        #expect(three.maxFilesSizeBytes == 4_194_304)
    }

    @Test("a board reports the poster name it actually shows")
    func defaultName() throws {
        #expect(try board("g").defaultName == "Anonymous")
    }

    @Test("boards are grouped, not left in one flat list")
    func categoriesAreFilledIn() throws {
        #expect(try board("g").category == "Interests")
        #expect(try board("po").category == "Creative")
        #expect(try boards().allSatisfy { !$0.category.isEmpty })
    }

    @Test("the worksafe flag and the archive flag are read")
    func flagsAreRead() throws {
        #expect(try board("3").isWorkSafe)
        #expect(try board("g").hasArchive)
    }

    /// Nothing on 4chan can be voted on, and that is what takes the like button
    /// off every post without a single change in any view.
    @Test("a 4chan board offers no voting, dice, tags or shield")
    func capabilitiesAreOff() throws {
        let g = try board("g")
        #expect(g.allowsLikes == false)
        #expect(g.allowsDices == false)
        #expect(g.allowsThreadTags == false)
        #expect(g.allowsShield == false)
    }

    @Test("a board with its own flags offers them as post icons")
    func boardFlagsBecomeIcons() throws {
        let pol = try board("pol")
        #expect(pol.allowsIcons)
        #expect(pol.icons.isEmpty == false)
    }
}

@Suite("4chan posts")
struct FourchanPostTests {
    private let endpoints = SiteEndpoints(SiteSelection(site: .fourchan))

    private func thread() throws -> ThreadResponse {
        try FourchanMapping.thread(
            from: try FixtureLoader.data(.fourchanThread),
            board: Board(id: "po", defaultName: "Anonymous"),
            endpoints: endpoints,
            decoder: JSONDecoder()
        )
    }

    private func post(_ wire: String) throws -> Post {
        let data = Data(wire.utf8)
        let decoded = try JSONDecoder().decode(FourchanWire.Post.self, from: data)
        return FourchanMapping.post(from: decoded, board: "po", endpoints: endpoints)
    }

    /// The shape most replies actually have: six keys, everything else absent.
    @Test("a post carrying only the keys 4chan always sends still decodes")
    func minimalPost() throws {
        let post = try post(#"""
        {"no": 2, "now": "09/16/26(Wed)23:23:58", "name": "Anonymous",
         "com": "text", "time": 1789615438, "resto": 1}
        """#)
        #expect(post.num == 2)
        #expect(post.parent == 1)
        #expect(post.isOriginalPost == false)
        // Injected by the mapper: the board is never on the wire.
        #expect(post.board == "po")
        #expect(post.files.isEmpty)
        #expect(post.date == "09/16/26(Wed)23:23:58")
        // Nil, not zero: nil is how the UI knows the site has no voting.
        #expect(post.likes == nil)
        #expect(post.dislikes == nil)
        // 4chan dropped email from its API, so nothing can arrive saged.
        #expect(post.isSage == false)
    }

    @Test("an opening post has no parent and says so")
    func openingPost() throws {
        let post = try post(#"{"no": 1, "resto": 0, "com": "op"}"#)
        #expect(post.isOriginalPost)
        #expect(post.threadNum == 1)
    }

    @Test("a poster ID and a staff badge are kept")
    func identityFields() throws {
        let post = try post(#"""
        {"no": 1, "resto": 0, "id": "XnBioefK", "capcode": "mod", "trip": "!!secure"}
        """#)
        #expect(post.posterID == "XnBioefK")
        #expect(post.capcode == "mod")
        #expect(post.tripcode == "!!secure")
    }

    @Test("a country becomes a flag the reader's own font can draw")
    func countryFlag() throws {
        let post = try post(#"{"no": 1, "country": "US", "country_name": "United States"}"#)
        #expect(post.icon?.flagEmoji == "🇺🇸")
        #expect(post.icon?.title == "United States")
    }

    /// `/pol/`'s board flags are jokes, not countries: `TR` is "Tree Hugger".
    /// Their images live under a path containing `/flags/`, so the path-based
    /// reader would confidently claim Turkey.
    @Test("a board flag is not mistaken for a country")
    func boardFlagIsNotACountry() throws {
        let post = try post(#"{"no": 1, "board_flag": "TR", "flag_name": "Tree Hugger"}"#)
        #expect(post.icon?.flagEmoji == nil)
        #expect(post.icon?.title == "Tree Hugger")
        #expect(post.icon?.imagePath?.hasSuffix("/flags/po/tr.gif") == true)
    }

    @Test("an archived thread is closed, because it takes no more posts")
    func archivedIsClosed() throws {
        #expect(try post(#"{"no": 1, "archived": 1}"#).isClosed)
        #expect(try post(#"{"no": 1, "closed": 1}"#).isClosed)
        #expect(try post(#"{"no": 1}"#).isClosed == false)
    }

    @Test("a sticky thread is recognised even though the site sends a flag")
    func sticky() throws {
        #expect(try post(#"{"no": 1, "sticky": 1}"#).isSticky)
    }

    @Test("posts are numbered by their position, which the site does not send")
    func postsAreNumbered() throws {
        let posts = try thread().posts
        #expect(posts.first?.number == 1)
        #expect(posts.last?.number == posts.count)
    }

    @Test("the thread's title comes from the opening post's subject")
    func threadTitle() throws {
        let response = try thread()
        #expect(response.title == response.posts.first?.subject)
    }
}

@Suite("4chan attachments")
struct FourchanAttachmentTests {
    private let endpoints = SiteEndpoints(SiteSelection(site: .fourchan))

    private func attachment(_ wire: String) throws -> NeechanAPI.Attachment? {
        let decoded = try JSONDecoder().decode(FourchanWire.Post.self, from: Data(wire.utf8))
        return FourchanMapping.attachment(from: decoded, board: "g", media: endpoints.media)
    }

    private let sample = #"""
    {"no": 1, "tim": 1789615517859518, "ext": ".png", "filename": "screenshot",
     "fsize": 2441945, "w": 663, "h": 395, "tn_w": 125, "tn_h": 74,
     "md5": "x+x6AxuQ+pNOplz/SP6nlQ=="}
    """#

    @Test("a file is addressed on the media host, in full")
    func absolutePaths() throws {
        let file = try #require(try attachment(sample))
        #expect(file.path == "https://i.4cdn.org/g/1789615517859518.png")
        // Always an s-suffixed JPEG, whatever the file itself is.
        #expect(file.thumbnail == "https://i.4cdn.org/g/1789615517859518s.jpg")
    }

    /// The assertion the whole media story rests on. Because these paths are
    /// absolute and `url(forPath:)` passes an absolute URL straight through,
    /// the gallery, the thumbnails and the archiver resolve a 4chan file with
    /// no idea that a second site exists.
    @Test("an absolute path survives being resolved against either site")
    func absolutePathsPassThroughUnchanged() throws {
        let file = try #require(try attachment(sample))
        for selection in [SiteSelection(site: .dvach), SiteSelection(site: .fourchan)] {
            let resolved = SiteEndpoints(selection).url(forPath: file.path)
            #expect(resolved?.absoluteString == file.path)
        }
    }

    @Test("a size reported in bytes becomes the kilobytes the model holds")
    func sizeIsConverted() throws {
        let file = try #require(try attachment(sample))
        #expect(file.sizeKB == 2384)
        #expect(abs(file.sizeBytes - 2_441_945) < 1024)
    }

    @Test("the type comes from the extension, since 4chan sends no code")
    func typeFromExtension() throws {
        #expect(try attachment(sample)?.effectiveType == AttachmentType.png)
    }

    @Test("the uploader's name keeps the extension the site strips off it")
    func fileName() throws {
        #expect(try attachment(sample)?.fullName == "screenshot.png")
    }

    @Test("the digest is kept exactly as sent, base64 and all")
    func md5IsUntouched() throws {
        #expect(try attachment(sample)?.md5 == "x+x6AxuQ+pNOplz/SP6nlQ==")
    }

    @Test("a spoilered file is one the reader has to ask to see")
    func spoiler() throws {
        let file = try attachment(#"{"no": 1, "tim": 1, "ext": ".jpg", "spoiler": 1}"#)
        #expect(file?.isNSFW == true)
    }

    @Test("a deleted file leaves no attachment at all")
    func deletedFile() throws {
        #expect(try attachment(#"{"no": 1, "tim": 1, "ext": ".jpg", "filedeleted": 1}"#) == nil)
    }

    @Test("a post with no file has none")
    func noFile() throws {
        #expect(try attachment(#"{"no": 1}"#) == nil)
    }
}

@Suite("4chan catalog, index and archive")
struct FourchanListingTests {
    private let endpoints = SiteEndpoints(SiteSelection(site: .fourchan))
    private let board = Board(id: "po", maxPages: 10, defaultName: "Anonymous")

    @Test("a catalog spread over pages becomes one list of threads")
    func catalogFlattensPages() throws {
        let catalog = try FourchanMapping.catalog(
            from: try FixtureLoader.data(.fourchanCatalog),
            board: board,
            endpoints: endpoints,
            decoder: JSONDecoder()
        )
        #expect(catalog.threads.isEmpty == false)
        #expect(catalog.board.id == "po")
        // 4chan's `replies` leaves out the opening post; 2ch's count includes
        // it, and everything downstream reads the 2ch meaning.
        for thread in catalog.threads {
            #expect(thread.postsCount == thread.replyCount + 1)
        }
    }

    @Test("an index page carries its threads and their previews")
    func indexPage() throws {
        let page = try FourchanMapping.boardPage(
            from: try FixtureLoader.data(.fourchanIndexPage1),
            board: board,
            page: 1,
            endpoints: endpoints,
            decoder: JSONDecoder()
        )
        #expect(page.currentPage == 1)
        #expect(page.threads.isEmpty == false)
        #expect(page.threads.allSatisfy { $0.opPost != nil })
        // Pages are 1-based here; there is no page zero to ask for.
        #expect(page.pages.first == 1)
    }

    @Test("an archive of bare numbers becomes a page of threads, newest first")
    func archiveFromBareNumbers() throws {
        let data = Data("[100, 200, 300]".utf8)
        let archive = try FourchanMapping.archive(
            from: data, board: "po", page: 0, decoder: JSONDecoder()
        )
        #expect(archive.threads.map(\.threadNum) == [300, 200, 100])
        #expect(archive.board == "po")
        // No titles to be had; the archive screen already falls back to /board/num.
        #expect(archive.threads.allSatisfy { $0.subject.isEmpty })
    }

    @Test("a long archive is paged, so the list keeps appending as it scrolls")
    func archiveIsPaged() throws {
        let data = Data("[\(Array(1...250).map(String.init).joined(separator: ","))]".utf8)
        let first = try FourchanMapping.archive(
            from: data, board: "po", page: 0, decoder: JSONDecoder()
        )
        let second = try FourchanMapping.archive(
            from: data, board: "po", page: 1, decoder: JSONDecoder()
        )
        #expect(first.threads.count == 100)
        #expect(first.lastPage == 2)
        #expect(Set(first.threads.map(\.threadNum))
            .isDisjoint(with: Set(second.threads.map(\.threadNum))))
    }

    @Test("the real archive fixture reads without complaint")
    func archiveFixture() throws {
        let archive = try FourchanMapping.archive(
            from: try FixtureLoader.data(.fourchanArchive),
            board: "po", page: 0, decoder: JSONDecoder()
        )
        #expect(archive.threads.isEmpty == false)
    }

    /// One request answers for a whole board, which is what replaces the
    /// count-only poll 4chan does not have.
    @Test("a board's thread list gives every thread's post count at once")
    func threadCounts() throws {
        let counts = try FourchanMapping.threadCounts(
            from: try FixtureLoader.data(.fourchanThreadsIndex),
            decoder: JSONDecoder()
        )
        #expect(counts.count > 10)
        let sample = try #require(counts.values.first)
        // `replies` excludes the opening post, exactly as 2ch's poll does.
        #expect(sample.postsCount >= 1)
    }
}
