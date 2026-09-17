import Foundation

/// `GET /{board}/catalog.json`
public struct CatalogResponse: Sendable, Decodable {
    public let board: Board
    public let threads: [ThreadSummary]
    /// Which catalog ordering the server applied, for example `standart`.
    public let filter: String?
    /// Server-relative path to the board banner.
    public let bannerImage: String?
    public let bannerLink: String?

    public init(
        board: Board,
        threads: [ThreadSummary],
        filter: String? = nil,
        bannerImage: String? = nil,
        bannerLink: String? = nil
    ) {
        self.board = board
        self.threads = threads
        self.filter = filter
        self.bannerImage = bannerImage
        self.bannerLink = bannerLink
    }

    private enum CodingKeys: String, CodingKey {
        case board, threads, filter
        case bannerImage = "board_banner_image"
        case bannerLink = "board_banner_link"
    }
}

/// `GET /{board}/index.json` and `GET /{board}/{page}.json`
public struct BoardPage: Sendable, Decodable {
    public let board: Board
    public let threads: [PagedThread]
    /// The page numbers the board currently has.
    public let pages: [Int]
    public let currentPage: Int
    /// Posts per hour, when the server reports it.
    public let boardSpeed: Int?

    public init(
        board: Board,
        threads: [PagedThread],
        pages: [Int] = [],
        currentPage: Int = 0,
        boardSpeed: Int? = nil
    ) {
        self.board = board
        self.threads = threads
        self.pages = pages
        self.currentPage = currentPage
        self.boardSpeed = boardSpeed
    }

    private enum CodingKeys: String, CodingKey {
        case board, threads, pages
        case currentPage = "current_page"
        case boardSpeed = "board_speed"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = try c.decode(Board.self, forKey: .board)
        threads = try c.decodeIfPresent([PagedThread].self, forKey: .threads) ?? []
        pages = try c.decodeIfPresent([Int].self, forKey: .pages) ?? []
        currentPage = try c.decodeIfPresent(Int.self, forKey: .currentPage) ?? 0
        boardSpeed = try c.decodeIfPresent(Int.self, forKey: .boardSpeed)
    }
}

/// A thread on a board page: the original post plus a preview of its replies.
public struct PagedThread: Sendable, Hashable, Identifiable, Decodable {
    public let threadNum: Int
    public let posts: [Post]
    public let postsCount: Int
    public let filesCount: Int

    public var id: Int { threadNum }
    public var opPost: Post? { posts.first }
    public var replyPreview: [Post] { Array(posts.dropFirst()) }

    public init(threadNum: Int, posts: [Post], postsCount: Int? = nil, filesCount: Int? = nil) {
        self.threadNum = threadNum
        self.posts = posts
        self.postsCount = postsCount ?? posts.count
        self.filesCount = filesCount ?? posts.reduce(0) { $0 + $1.files.count }
    }

    private enum CodingKeys: String, CodingKey {
        case threadNum = "thread_num"
        case posts
        case postsCount = "posts_count"
        case filesCount = "files_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = try c.decodeIfPresent([Post].self, forKey: .posts) ?? []
        threadNum = try c.decodeIfPresent(Int.self, forKey: .threadNum) ?? (posts.first?.num ?? 0)
        postsCount = try c.decodeIfPresent(Int.self, forKey: .postsCount) ?? posts.count
        filesCount = try c.decodeIfPresent(Int.self, forKey: .filesCount)
            ?? posts.reduce(0) { $0 + $1.files.count }
    }
}

/// `GET /{board}/res/{thread}.json`
public struct ThreadResponse: Sendable, Decodable {
    public let board: Board
    public let posts: [Post]
    public let currentThread: Int
    /// Highest post number in the thread; the anchor for incremental refreshes.
    public let maxNum: Int
    public let postsCount: Int
    public let filesCount: Int
    public let uniquePosters: Int
    public let isClosed: Bool
    public let title: String
    /// Server-relative path to the thread's first image, used as its poster.
    public let firstImage: String?

    public init(
        board: Board,
        posts: [Post],
        currentThread: Int? = nil,
        maxNum: Int? = nil,
        postsCount: Int? = nil,
        filesCount: Int? = nil,
        uniquePosters: Int = 0,
        isClosed: Bool = false,
        title: String = "",
        firstImage: String? = nil
    ) {
        self.board = board
        self.posts = posts
        self.currentThread = currentThread ?? (posts.first?.num ?? 0)
        self.maxNum = maxNum ?? (posts.last?.num ?? 0)
        self.postsCount = postsCount ?? posts.count
        self.filesCount = filesCount ?? posts.reduce(0) { $0 + $1.files.count }
        self.uniquePosters = uniquePosters
        self.isClosed = isClosed
        self.title = title
        self.firstImage = firstImage
    }

    private enum CodingKeys: String, CodingKey {
        case board, threads, title
        case currentThread = "current_thread"
        case maxNum = "max_num"
        case postsCount = "posts_count"
        case filesCount = "files_count"
        case uniquePosters = "unique_posters"
        case isClosed = "is_closed"
        case firstImage = "thread_first_image"
    }

    private struct ThreadContainer: Decodable {
        let posts: [Post]
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = try c.decode(Board.self, forKey: .board)
        let containers = try c.decodeIfPresent([ThreadContainer].self, forKey: .threads) ?? []
        posts = containers.flatMap(\.posts)
        currentThread = try c.decodeIfPresent(Int.self, forKey: .currentThread) ?? (posts.first?.num ?? 0)
        maxNum = try c.decodeIfPresent(Int.self, forKey: .maxNum) ?? (posts.last?.num ?? 0)
        postsCount = try c.decodeIfPresent(Int.self, forKey: .postsCount) ?? posts.count
        filesCount = try c.decodeIfPresent(Int.self, forKey: .filesCount)
            ?? posts.reduce(0) { $0 + $1.files.count }
        uniquePosters = try c.decodeIfPresent(Int.self, forKey: .uniquePosters) ?? 0
        isClosed = (try c.decodeIfPresent(Int.self, forKey: .isClosed) ?? 0) != 0
        title = HTMLEntities.decode(try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        firstImage = try c.decodeIfPresent(String.self, forKey: .firstImage)
    }
}

/// `GET /api/mobile/v2/after/{board}/{thread}/{num}`
///
/// Returns posts with a number greater than or equal to the one asked for, so
/// the first element is the anchor the caller already has.
public struct AfterResponse: Sendable, Decodable {
    public let result: Int
    public let error: DvachAPIError?
    public let uniquePosters: Int
    public let posts: [Post]

    public init(result: Int = 1, error: DvachAPIError? = nil, uniquePosters: Int = 0, posts: [Post]) {
        self.result = result
        self.error = error
        self.uniquePosters = uniquePosters
        self.posts = posts
    }

    private enum CodingKeys: String, CodingKey {
        case result, error, posts
        case uniquePosters = "unique_posters"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decodeIfPresent(Int.self, forKey: .result) ?? 0
        error = try c.decodeIfPresent(DvachAPIError.self, forKey: .error)
        uniquePosters = try c.decodeIfPresent(Int.self, forKey: .uniquePosters) ?? 0
        posts = try c.decodeIfPresent([Post].self, forKey: .posts) ?? []
    }
}

/// `GET /api/mobile/v2/info/{board}/{thread}` — the cheap watcher poll.
public struct InfoResponse: Sendable, Decodable {
    public struct ThreadInfo: Sendable, Decodable {
        public let num: Int
        /// Reply count, excluding the original post.
        public let posts: Int
        public let timestamp: Int

        public init(num: Int, posts: Int, timestamp: Int) {
            self.num = num
            self.posts = posts
            self.timestamp = timestamp
        }
    }

    public let result: Int
    public let error: DvachAPIError?
    public let thread: ThreadInfo?

    public init(result: Int = 1, error: DvachAPIError? = nil, thread: ThreadInfo?) {
        self.result = result
        self.error = error
        self.thread = thread
    }
}

/// `GET /api/mobile/v2/post/{board}/{num}`
public struct SinglePostResponse: Sendable, Decodable {
    public let result: Int
    public let error: DvachAPIError?
    public let post: Post?

    public init(result: Int = 1, error: DvachAPIError? = nil, post: Post?) {
        self.result = result
        self.error = error
        self.post = post
    }
}

/// `POST /user/search?json=1`
public struct SearchResponse: Sendable, Decodable {
    public let board: Board?
    public let posts: [Post]
    public let error: DvachAPIError?

    public init(board: Board? = nil, posts: [Post], error: DvachAPIError? = nil) {
        self.board = board
        self.posts = posts
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case board, posts, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = try? c.decodeIfPresent(Board.self, forKey: .board)
        posts = try c.decodeIfPresent([Post].self, forKey: .posts) ?? []
        error = try c.decodeIfPresent(DvachAPIError.self, forKey: .error)
    }
}

/// `GET /{board}/arch/index.json` and `GET /{board}/arch/{page}.json`
///
/// The archive does not reuse the catalog's shape: a row carries only enough to
/// list the thread, and its `board` is a plain board code rather than a board
/// object. Opening an archived thread fetches it in full.
public struct ArchiveResponse: Sendable, Decodable {
    public let board: String
    /// The last page number the archive has; page 0 is the newest.
    public let lastPage: Int
    public let pages: [Int]
    public let threads: [ArchivedThread]

    public init(board: String, lastPage: Int, pages: [Int], threads: [ArchivedThread]) {
        self.board = board
        self.lastPage = lastPage
        self.pages = pages
        self.threads = threads
    }

    private enum CodingKeys: String, CodingKey {
        case board, threads, pages, page
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = (try? c.decodeIfPresent(String.self, forKey: .board)) ?? ""
        lastPage = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        pages = try c.decodeIfPresent([Int].self, forKey: .pages) ?? []
        threads = try c.decodeIfPresent([ArchivedThread].self, forKey: .threads) ?? []
    }
}

/// One row of an archive page.
public struct ArchivedThread: Sendable, Hashable, Identifiable, Decodable {
    public let board: String
    public let threadNum: Int
    public let subject: String
    /// The archive folder the thread's files live under, as `YYYY-MM-DD`.
    public let date: String
    public let timestamp: Int

    public var id: Int { threadNum }

    /// When the thread was archived, from the server's own timestamp.
    public var archivedAt: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    public init(
        board: String,
        threadNum: Int,
        subject: String = "",
        date: String = "",
        timestamp: Int = 0
    ) {
        self.board = board
        self.threadNum = threadNum
        self.subject = subject
        self.date = date
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case board, subject, date, timestamp
        case thread
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = try c.decodeIfPresent(String.self, forKey: .board) ?? ""
        threadNum = try c.decodeIfPresent(Int.self, forKey: .thread) ?? 0
        subject = HTMLEntities.decode(try c.decodeIfPresent(String.self, forKey: .subject) ?? "")
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
    }
}
