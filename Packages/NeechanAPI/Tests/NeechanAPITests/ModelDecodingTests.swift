import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanAPI

@Suite("Model decoding")
struct ModelDecodingTests {
    // MARK: Boards

    @Test("the board list decodes as a bare array")
    func decodesBoards() throws {
        let boards = try FixtureLoader.decode([Board].self, from: .boards)
        #expect(boards.count >= 5)

        let b = try #require(boards.first { $0.id == "b" })
        #expect(b.name.isEmpty == false)
        #expect(b.category.isEmpty == false)
        #expect(b.bumpLimit == 500)
        #expect(b.maxComment == 15000)
        #expect(b.defaultName == "Аноним")
        #expect(b.allowsPosting)
        #expect(b.allowsSage)
        #expect(b.allowsSubject == false)
        #expect(b.allowsLikes == false)
        #expect(b.fileTypes.contains("webm"))
    }

    @Test("max file size is exposed in bytes as well as the raw kilobytes")
    func boardFileSizeUnits() throws {
        let boards = try FixtureLoader.decode([Board].self, from: .boards)
        let b = try #require(boards.first { $0.id == "b" })
        #expect(b.maxFilesSizeKB > 0)
        #expect(b.maxFilesSizeBytes == b.maxFilesSizeKB * 1024)
    }

    @Test("a board with thread tags exposes them")
    func boardTags() throws {
        let boards = try FixtureLoader.decode([Board].self, from: .boards)
        // `tags` is absent on most boards and must decode to an empty array.
        #expect(boards.allSatisfy { $0.tags.isEmpty || $0.allowsThreadTags })
    }

    // MARK: Catalog

    @Test("the catalog decodes its board and thread summaries")
    func decodesCatalog() throws {
        let catalog = try FixtureLoader.decode(CatalogResponse.self, from: .catalog)
        #expect(catalog.board.id.isEmpty == false)
        #expect(catalog.threads.count >= 10)

        let thread = try #require(catalog.threads.first)
        #expect(thread.id == thread.opPost.num)
        #expect(thread.opPost.isOriginalPost)
        #expect(thread.postsCount > 0)
    }

    @Test("sticky is a priority, not a flag")
    func stickyIsPriority() throws {
        let catalog = try FixtureLoader.decode(CatalogResponse.self, from: .catalog)
        // Any pinned thread must report a positive priority and read as pinned.
        for thread in catalog.threads where thread.opPost.stickyPriority > 0 {
            #expect(thread.opPost.isSticky)
        }
        #expect(catalog.threads.allSatisfy { $0.opPost.stickyPriority >= 0 })
    }

    // MARK: Paged index

    @Test("the paged index decodes pages and per-thread post previews")
    func decodesBoardPage() throws {
        let page = try FixtureLoader.decode(BoardPage.self, from: .indexPage0)
        #expect(page.currentPage == 0)
        #expect(page.pages.count > 1)
        #expect(page.threads.isEmpty == false)

        let thread = try #require(page.threads.first)
        #expect(thread.threadNum > 0)
        #expect(thread.posts.isEmpty == false)
        #expect(thread.posts.first?.num == thread.threadNum)
    }

    @Test("page one reports its own number")
    func decodesSecondPage() throws {
        let page = try FixtureLoader.decode(BoardPage.self, from: .indexPage1)
        #expect(page.currentPage == 1)
        #expect(page.boardSpeed != nil)
    }

    // MARK: Thread

    @Test("a thread decodes its posts, counts and attachments")
    func decodesThread() throws {
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        #expect(response.posts.isEmpty == false)
        #expect(response.currentThread == response.posts[0].num)
        #expect(response.maxNum == response.posts.last?.num)
        #expect(response.uniquePosters > 0)
        #expect(response.title.isEmpty == false)
        #expect(response.isClosed == false)

        let withFiles = try #require(response.posts.first { !$0.files.isEmpty })
        let file = try #require(withFiles.files.first)
        #expect(file.path.hasPrefix("/"))
        #expect(file.thumbnail.hasPrefix("/"))
        #expect(file.width > 0 && file.height > 0)
        #expect(file.sizeKB > 0)
        #expect(file.sizeBytes == file.sizeKB * 1024)
    }

    @Test("posts whose files field is null decode as having no attachments")
    func nullFilesDecodesEmpty() throws {
        let json = Data(#"{"num":1,"comment":"hi","files":null}"#.utf8)
        let post = try JSONDecoder().decode(Post.self, from: json)
        #expect(post.files.isEmpty)
    }

    @Test("a post carrying only a number still decodes")
    func minimalPostDecodes() throws {
        let post = try JSONDecoder().decode(Post.self, from: Data(#"{"num":42}"#.utf8))
        #expect(post.num == 42)
        #expect(post.comment.isEmpty)
        #expect(post.isOriginalPost)  // parent defaults to 0
    }

    // MARK: Mobile API

    @Test("the after response yields the anchor post and the newer ones")
    func decodesAfter() throws {
        let after = try FixtureLoader.decode(AfterResponse.self, from: .threadAfter)
        #expect(after.result == 1)
        #expect(after.error == nil)
        #expect(after.posts.count >= 2)
        #expect(after.posts == after.posts.sorted { $0.num < $1.num })
    }

    @Test("the info response reports the thread's post count")
    func decodesInfo() throws {
        let info = try FixtureLoader.decode(InfoResponse.self, from: .threadInfo)
        #expect(info.result == 1)
        let thread = try #require(info.thread)
        #expect(thread.num > 0)
        #expect(thread.posts > 0)
        #expect(thread.timestamp > 0)
    }

    @Test("a single post lookup decodes")
    func decodesSinglePost() throws {
        let response = try FixtureLoader.decode(SinglePostResponse.self, from: .postSingle)
        #expect(response.result == 1)
        #expect(try #require(response.post).num > 0)
    }

    @Test("an error envelope decodes into a typed error")
    func decodesErrorEnvelope() throws {
        let response = try FixtureLoader.decode(AfterResponse.self, from: .errorNoPost)
        #expect(response.result == 0)
        let error = try #require(response.error)
        #expect(error.code == .noPost)
        #expect(error.message.isEmpty == false)
    }

    @Test("search results decode posts alongside the board")
    func decodesSearch() throws {
        let response = try FixtureLoader.decode(SearchResponse.self, from: .searchResult)
        #expect(response.posts.isEmpty == false)
        #expect(response.board?.id.isEmpty == false)
    }

    @Test("a too-short search query surfaces the field-too-small code")
    func decodesSearchTooShort() throws {
        let response = try FixtureLoader.decode(SearchResponse.self, from: .searchTooShort)
        #expect(response.error?.code == .fieldTooSmall)
    }

    // MARK: Attachment types

    @Test("known attachment type codes map to cases", arguments: [
        (1, AttachmentType.jpeg), (2, .png), (3, .apng), (4, .gif),
        (5, .bmp), (6, .webm), (10, .mp4), (100, .sticker)
    ])
    func knownAttachmentTypes(raw: Int, expected: AttachmentType) {
        #expect(AttachmentType(rawValue: raw) == expected)
        #expect(expected.rawValue == raw)
    }

    @Test("an unrecognised type code is preserved rather than dropped")
    func unknownAttachmentTypeRoundTrips() {
        let type = AttachmentType(rawValue: 77)
        #expect(type == .unknown(77))
        #expect(type.rawValue == 77)
        #expect(type.isVideo == false)
    }

    @Test("webp served under a jpeg type code is detected from the file name")
    func webpDetectedByExtension() throws {
        let json = Data("""
        {"name":"1.webp","fullname":"x.webp","displayname":"x.webp",
         "path":"/b/src/1/1.webp","thumbnail":"/b/thumb/1/1s.webp","type":1,
         "size":10,"width":100,"height":100,"tn_width":50,"tn_height":50}
        """.utf8)
        let attachment = try JSONDecoder().decode(Attachment.self, from: json)
        #expect(attachment.declaredType == .jpeg)
        #expect(attachment.effectiveType == .webp)
        #expect(attachment.isVideo == false)
    }

    @Test("webm keeps its type and reads as video")
    func webmIsVideo() throws {
        let response = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let videos = response.posts.flatMap(\.files).filter(\.isVideo)
        for video in videos {
            #expect(video.effectiveType == .webm || video.effectiveType == .mp4)
        }
    }

    @Test("video attachments expose their duration when the server sends one")
    func videoDuration() throws {
        let json = Data("""
        {"name":"1.webm","fullname":"x.webm","displayname":"x.webm",
         "path":"/b/src/1/1.webm","thumbnail":"/b/thumb/1/1s.jpg","type":6,
         "size":2048,"width":640,"height":480,"tn_width":160,"tn_height":120,
         "duration":"00:01:23","duration_secs":83}
        """.utf8)
        let attachment = try JSONDecoder().decode(Attachment.self, from: json)
        #expect(attachment.isVideo)
        #expect(attachment.durationSeconds == 83)
        #expect(attachment.durationText == "00:01:23")
    }

    // MARK: Robustness

    @Test("every recorded thread post decodes without throwing")
    func everyRecordedPostDecodes() throws {
        let thread = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        let catalog = try FixtureLoader.decode(CatalogResponse.self, from: .catalog)
        let page = try FixtureLoader.decode(BoardPage.self, from: .indexPage0)
        #expect(thread.posts.allSatisfy { $0.num > 0 })
        #expect(catalog.threads.allSatisfy { $0.opPost.num > 0 })
        #expect(page.threads.allSatisfy { $0.threadNum > 0 })
    }
}

@Suite("Archive decoding")
struct ArchiveDecodingTests {
    @Test("an archive index lists its threads and its page numbers")
    func archiveIndex() throws {
        let response = try FixtureLoader.decode(ArchiveResponse.self, from: .archiveIndex)

        #expect(response.board == "a")
        #expect(response.lastPage > 0)
        #expect(response.pages.first == 0)
        #expect(response.pages.contains(response.lastPage))
        #expect(response.threads.isEmpty == false)
    }

    @Test("an archived thread carries the folder date its files live under")
    func archivedThread() throws {
        let response = try FixtureLoader.decode(ArchiveResponse.self, from: .archiveIndex)
        let thread = try #require(response.threads.first)

        #expect(thread.threadNum > 0)
        #expect(thread.board == "a")
        #expect(thread.subject.isEmpty == false)
        #expect(thread.date.count == "2024-06-01".count)
        #expect(thread.archivedAt.timeIntervalSince1970 > 0)
    }
}

/// The site escapes the plain-text fields as HTML but sends them outside any
/// markup, so a subject reading "> цитата" arrives as "&gt; цитата". Shown as
/// it arrives, a reader sees the escape rather than the character.
@Suite("Escaped text fields")
struct EscapedFieldsTests {
    private func post(_ json: String) throws -> Post {
        try JSONDecoder().decode(Post.self, from: Data(json.utf8))
    }

    @Test("a subject is unescaped")
    func subject() throws {
        let decoded = try post(##"{"num":1,"subject":"&gt; Таких женщин &amp; прочих"}"##)
        #expect(decoded.subject == "> Таких женщин & прочих")
    }

    @Test("a poster's name and tripcode are unescaped")
    func nameAndTrip() throws {
        let decoded = try post(##"{"num":1,"name":"Ан&oacute;ним","trip":"!&quot;x&quot;"}"##)
        #expect(decoded.name == "Анóним")
        #expect(decoded.tripcode == "!\"x\"")
    }

    @Test("the comment is left alone, because the parser needs its markup")
    func commentKeepsItsMarkup() throws {
        let decoded = try post(##"{"num":1,"comment":"<span>&gt; q</span>"}"##)
        #expect(decoded.comment == "<span>&gt; q</span>")
    }

    @Test("a thread's title is unescaped")
    func threadTitle() throws {
        let response = try JSONDecoder().decode(
            ThreadResponse.self,
            from: Data(##"{"board":{"id":"b","name":"Бред"},"title":"&gt; тема","threads":[{"posts":[]}]}"##.utf8)
        )
        #expect(response.title == "> тема")
    }

    @Test("text with nothing escaped in it is unchanged")
    func plainTextIsUntouched() throws {
        let decoded = try post(##"{"num":1,"subject":"обычная тема 100% & готово"}"##)
        #expect(decoded.subject == "обычная тема 100% & готово")
    }
}

/// Boards with poster IDs and country flags send both inside HTML in fields
/// that are otherwise plain text.
@Suite("Poster identity")
struct PosterIdentityTests {
    private func post(_ json: String) throws -> Post {
        try JSONDecoder().decode(Post.self, from: Data(json.utf8))
    }

    @Test("a plain name is left as it is")
    func plainName() throws {
        let decoded = try post(##"{"num":1,"name":"Аноним&nbsp;"}"##)
        #expect(decoded.name == "Аноним")
        #expect(decoded.posterID == nil)
    }

    /// /po/ gives every poster a generated nickname inside a coloured span.
    @Test("a generated poster name is separated from the word Аноним")
    func posterIdentity() throws {
        let decoded = try post(##"{"num":1,"name":"Аноним&nbsp;ID:&nbsp;<span id=\"id_tag_a68\" style=\"color:rgb(24,212,14);\">Одержимый&nbsp;Мартовский Заяц</span>&nbsp;"}"##)

        #expect(decoded.name == "Аноним")
        #expect(decoded.posterID == "Одержимый Мартовский Заяц")
        #expect(decoded.posterIDColor == PostColor(red: 24, green: 212, blue: 14))
    }

    @Test("a poster name with no colour still comes through")
    func posterIdentityWithoutColour() throws {
        let decoded = try post(##"{"num":1,"name":"Аноним ID: <span>Тихий Ёж</span>"}"##)

        #expect(decoded.posterID == "Тихий Ёж")
        #expect(decoded.posterIDColor == nil)
    }

    @Test("a country flag becomes an emoji, so nothing has to be fetched")
    func countryFlag() throws {
        let decoded = try post(##"{"num":1,"icon":"<img hspace=\"3\" src=\"/flags/RU.png\" border=\"0\" />"}"##)

        #expect(decoded.icon?.flagEmoji == "🇷🇺")
        #expect(decoded.icon?.imagePath == "/flags/RU.png")
    }

    @Test(
        "every country code maps to its own flag",
        arguments: [("AL", "🇦🇱"), ("US", "🇺🇸"), ("JP", "🇯🇵"), ("de", "🇩🇪")]
    )
    func flagCodes(code: String, expected: String) throws {
        let decoded = try post(##"{"num":1,"icon":"<img src=\"/flags/\##(code).png\" />"}"##)
        #expect(decoded.icon?.flagEmoji == expected)
    }

    /// Some boards use board-specific badges rather than flags; those have no
    /// emoji and are shown as the image the server names.
    @Test("a badge that is not a flag keeps its image and its title")
    func badgeIcon() throws {
        let decoded = try post(##"{"num":1,"icon":"<img src=\"/icons/po/lenin.png\" title=\"Ленин\" />"}"##)

        #expect(decoded.icon?.flagEmoji == nil)
        #expect(decoded.icon?.imagePath == "/icons/po/lenin.png")
        #expect(decoded.icon?.title == "Ленин")
    }

    @Test("a post with no icon has none")
    func noIcon() throws {
        #expect(try post(##"{"num":1}"##).icon == nil)
        #expect(try post(##"{"num":1,"icon":""}"##).icon == nil)
    }
}
