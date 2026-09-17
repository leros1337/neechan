import Foundation

/// Turns 4chan's JSON into the models the rest of the app already reads.
///
/// The neutral models stay 2ch-shaped in name because that is where they came
/// from, but nothing downstream — the merger, the reply index, the filter
/// engine, every row on screen — needs to know which site a post was read from.
/// Keeping that true is the whole job of this file.
enum FourchanMapping {
    /// Files live on a host of their own, so paths are emitted absolute.
    ///
    /// `SiteEndpoints.url(forPath:)` returns an absolute URL unchanged, which
    /// is what lets the gallery, the thumbnails and the archiver resolve these
    /// with no idea that a second site exists.
    static func attachment(
        from post: FourchanWire.Post,
        board: String,
        media: URL
    ) -> Attachment? {
        guard
            post.fileDeleted != 1,
            let tim = post.tim,
            let ext = post.ext
        else {
            return nil
        }
        let base = media.absoluteString
        // The uploader's name arrives without its extension, and escaped.
        let original = HTMLEntities.decode(post.filename ?? String(tim)) + ext
        return Attachment(
            name: "\(tim)\(ext)",
            fullName: original,
            displayName: original,
            path: "\(base)/\(board)/\(tim)\(ext)",
            // Always an s-suffixed JPEG, whatever the file itself is.
            thumbnail: "\(base)/\(board)/\(tim)s.jpg",
            // Base64 of the raw digest, not 2ch's hex. Kept as sent: it is what
            // 4chan's own duplicate detection uses, and nothing here reads it.
            md5: post.md5,
            declaredType: AttachmentType(fileExtension: ext),
            // `fsize` is bytes; 2ch's `size` is already kilobytes.
            sizeKB: (post.fsize ?? 0) / 1024,
            width: post.w ?? 0,
            height: post.h ?? 0,
            thumbnailWidth: post.tnW ?? 0,
            thumbnailHeight: post.tnH ?? 0,
            // 4chan's spoiler means "hide until tapped", which is what this
            // drives. Board-level worksafeness is a different question.
            isNSFW: (post.spoiler ?? 0) != 0
        )
    }

    /// The badge beside a poster's name.
    ///
    /// Only `country` yields an emoji. `/pol/` and `/mlp/` also carry *board*
    /// flags whose codes are jokes rather than countries — `TR` is "Tree
    /// Hugger" — and their images sit under a path containing `/flags/`, so
    /// running them through the path-based reader would confidently claim
    /// Turkey. They get their image and their name and no emoji.
    static func icon(from post: FourchanWire.Post, board: String, assets: URL) -> PostIcon? {
        if let country = post.country {
            return PostIcon(
                imagePath: "\(assets.absoluteString)/image/country/\(country.lowercased()).gif",
                title: post.countryName,
                flagEmoji: PostIcon.flagEmoji(forCountryCode: country)
            )
        }
        if let flag = post.boardFlag {
            return PostIcon(
                imagePath: "\(assets.absoluteString)/image/flags/\(board)/\(flag.lowercased()).gif",
                title: post.flagName,
                flagEmoji: nil
            )
        }
        return nil
    }

    static func post(
        from wire: FourchanWire.Post,
        board: String,
        number: Int? = nil,
        endpoints: SiteEndpoints
    ) -> Post {
        let file = attachment(from: wire, board: board, media: endpoints.media)
        let files: [Attachment] = file.map { [$0] } ?? []
        let badge = icon(from: wire, board: board, assets: endpoints.assets)
        let name = HTMLEntities.decode(wire.name ?? "Anonymous")
        let subject = HTMLEntities.decode(wire.sub ?? "")
        let tripcode = HTMLEntities.decode(wire.trip ?? "")
        let lastHit = wire.lastModified ?? wire.time ?? 0
        let isClosed = (wire.closed ?? 0) != 0 || (wire.archived ?? 0) != 0
        return Post(
            num: wire.no,
            // `resto` is 0 on an OP, exactly as 2ch's `parent` is.
            parent: wire.resto ?? 0,
            // Never on the wire: the board comes from the request that asked.
            board: board,
            timestamp: wire.time ?? 0,
            lastHit: lastHit,
            // Server-preformatted on both sites; passed through as sent.
            date: wire.now ?? "",
            // Not entity-decoded: the parser wants the entities alongside the
            // tags, the same rule the 2ch decoder follows.
            comment: wire.com ?? "",
            subject: subject,
            // Plain text here, so it is not run through `PosterName`: 4chan
            // never wraps a poster ID in a span the way 2ch does.
            name: name,
            // 4chan dropped the email field from its API. `isSage` is therefore
            // always false, which is correct: it does not show sage either.
            email: "",
            tripcode: tripcode,
            icon: badge,
            posterID: wire.id,
            // Derived client-side from the ID's hash on the site itself; the UI
            // already handles its absence.
            posterIDColor: nil,
            files: files,
            // A flag here rather than 2ch's priority. `isSticky` reads `> 0`,
            // and a column of equal values leaves the catalog sort untouched.
            stickyPriority: wire.sticky ?? 0,
            // An archived thread takes no posts, which is what closed means to
            // everything downstream — including the watcher's long backoff.
            isClosed: isClosed,
            // Nil rather than zero: nil is how the UI knows the site has no
            // voting at all, which is what hides the control.
            likes: nil,
            dislikes: nil,
            capcode: wire.capcode,
            number: number
        )
    }

    static func boards(from data: Data, decoder: JSONDecoder) throws -> [Board] {
        try decoder.decode(FourchanWire.BoardsResponse.self, from: data).boards.map(board)
    }

    static func board(_ wire: FourchanWire.Board) -> Board {
        let flags = wire.boardFlags ?? [:]
        let category = FourchanBoardCategories.category(
            for: wire.board,
            isWorkSafe: wire.wsBoard == 1
        )
        let info = HTMLEntities.decode(wire.metaDescription ?? "")
        let maxFileSizeKB = max(wire.maxFilesize ?? 0, wire.maxWebmFilesize ?? 0) / 1024
        let fileTypes: [String] = wire.textOnly == 1 ? [] : ["jpg", "png", "gif", "webm"]
        let allowsNames = wire.forcedAnon != 1
        let icons: [BoardIcon] = flags
            .sorted { $0.key < $1.key }
            .enumerated()
            .map { index, entry in
                BoardIcon(
                    num: index,
                    name: entry.value,
                    url: "/image/flags/\(wire.board)/\(entry.key.lowercased()).gif"
                )
            }
        return Board(
            id: wire.board,
            name: wire.title,
            category: category,
            // Escaped on the wire: `"/3/ - 3DCG" is 4chan's board for…`.
            info: info,
            threadsPerPage: wire.perPage ?? 0,
            bumpLimit: wire.bumpLimit ?? 0,
            maxPages: wire.pages ?? 0,
            defaultName: "Anonymous",
            maxComment: wire.maxCommentChars ?? 2000,
            // Bytes on the wire, despite the documentation; the model wants
            // kilobytes, and `maxFilesSizeBytes` then round-trips exactly.
            maxFilesSizeKB: maxFileSizeKB,
            // 4chan does not enumerate these; this is what every board takes.
            fileTypes: fileTypes,
            icons: icons,
            allowsNames: allowsNames,
            allowsTripcodes: allowsNames,
            allowsSubject: true,
            allowsSage: true,
            allowsIcons: !flags.isEmpty,
            allowsFlags: wire.countryFlags == 1,
            // No dice rolls, no shield, no thread tags, and — the one that
            // matters — no voting, which is what takes the like button off
            // every post without a single change in the UI.
            allowsDices: false,
            allowsShield: false,
            allowsThreadTags: false,
            allowsPosting: true,
            allowsLikes: false,
            allowsOekaki: wire.oekaki == 1,
            isWorkSafe: wire.wsBoard == 1,
            hasArchive: wire.isArchived == 1
        )
    }

    static func catalog(
        from data: Data,
        board: Board,
        endpoints: SiteEndpoints,
        decoder: JSONDecoder
    ) throws -> CatalogResponse {
        let pages = try decoder.decode([FourchanWire.CatalogPage].self, from: data)
        let threads = pages.flatMap(\.threads).map { row in
            ThreadSummary(
                opPost: post(from: row.post, board: board.id, endpoints: endpoints),
                // 2ch counts the opening post; 4chan's `replies` does not.
                postsCount: (row.replies ?? 0) + 1,
                filesCount: (row.images ?? 0) + (row.post.tim == nil ? 0 : 1)
            )
        }
        return CatalogResponse(board: board, threads: threads)
    }

    static func boardPage(
        from data: Data,
        board: Board,
        page: Int,
        endpoints: SiteEndpoints,
        decoder: JSONDecoder
    ) throws -> BoardPage {
        let index = try decoder.decode(FourchanWire.IndexPage.self, from: data)
        let threads = index.threads.map { container in
            let posts = container.posts.map {
                post(from: $0, board: board.id, endpoints: endpoints)
            }
            let op = container.posts.first
            return PagedThread(
                threadNum: op?.no ?? 0,
                posts: posts,
                postsCount: (op?.replies ?? 0) + 1,
                filesCount: (op?.images ?? 0) + (op?.tim == nil ? 0 : 1)
            )
        }
        return BoardPage(
            board: board,
            threads: threads,
            // Pages are 1-based and the board says how many it has.
            pages: Array(1...max(board.maxPages, 1)),
            currentPage: max(1, page)
        )
    }

    static func thread(
        from data: Data,
        board: Board,
        endpoints: SiteEndpoints,
        decoder: JSONDecoder
    ) throws -> ThreadResponse {
        let container = try decoder.decode(FourchanWire.ThreadContainer.self, from: data)
        let posts = container.posts.enumerated().map { index, wire in
            // 4chan does not number posts within a thread; the position is
            // filled in while walking them, so "post #N" works here too.
            post(from: wire, board: board.id, number: index + 1, endpoints: endpoints)
        }
        let op = container.posts.first
        return ThreadResponse(
            board: board,
            posts: posts,
            uniquePosters: op?.uniqueIPs ?? 0,
            isClosed: (op?.closed ?? 0) != 0 || (op?.archived ?? 0) != 0,
            title: HTMLEntities.decode(op?.sub ?? "")
        )
    }

    /// One page of the archive.
    ///
    /// 4chan's archive is a bare array of thread numbers, oldest first, and
    /// nothing else: no titles, no dates. It is reversed so the newest is first
    /// the way 2ch's is, and paged here so the archive screen's append-on-scroll
    /// keeps working unchanged. Re-fetching the whole list per page costs
    /// nothing — it is a few kilobytes the session already holds.
    static func archive(
        from data: Data,
        board: String,
        page: Int,
        decoder: JSONDecoder
    ) throws -> ArchiveResponse {
        let numbers = try decoder.decode([Int].self, from: data).reversed()
        let perPage = 100
        let pageCount = max(1, Int(ceil(Double(numbers.count) / Double(perPage))))
        let index = max(0, min(page, pageCount - 1))
        let slice = numbers.dropFirst(index * perPage).prefix(perPage)
        return ArchiveResponse(
            board: board,
            lastPage: pageCount - 1,
            pages: Array(0..<pageCount),
            // The subject stays empty: the archive screen already falls back to
            // /board/number, and filling these in would cost one request each.
            threads: slice.map { ArchivedThread(board: board, threadNum: $0) }
        )
    }

    /// Every thread on a board with its reply count, which is the whole of a
    /// watcher pass on this site.
    static func threadCounts(from data: Data, decoder: JSONDecoder) throws -> [Int: ThreadCount] {
        let pages = try decoder.decode([FourchanWire.ThreadListPage].self, from: data)
        return pages.flatMap(\.threads).reduce(into: [:]) { counts, stub in
            counts[stub.no] = ThreadCount(
                threadNum: stub.no,
                // `replies` excludes the opening post, exactly as 2ch's
                // count-only poll does.
                postsCount: (stub.replies ?? 0) + 1,
                lastModified: stub.lastModified ?? 0
            )
        }
    }
}

/// What a whole-board poll learns about one thread.
public struct ThreadCount: Sendable, Hashable {
    public let threadNum: Int
    /// Including the opening post.
    public let postsCount: Int
    public let lastModified: Int

    public init(threadNum: Int, postsCount: Int, lastModified: Int) {
        self.threadNum = threadNum
        self.postsCount = postsCount
        self.lastModified = lastModified
    }
}
