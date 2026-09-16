import Foundation
import NeechanAPI
import NeechanSettings

/// Thread listings for a board, in either of the site's two shapes.
public actor CatalogRepository {
    /// A whole catalog, already ordered.
    public struct CatalogPage: Sendable {
        public let board: Board
        public let threads: [ThreadSummary]
        public let bannerImagePath: String?
    }

    /// One page of the paged index.
    public struct IndexPage: Sendable {
        public let board: Board
        public let threads: [PagedThread]
        public let currentPage: Int
        public let pageCount: Int
        /// Posts per hour, when the server reports it.
        public let boardSpeed: Int?

        public var hasNextPage: Bool { currentPage + 1 < pageCount }

        /// The page's threads in the shape the catalog uses, so both ways of
        /// browsing a board draw the same rows.
        public var summaries: [ThreadSummary] {
            threads.compactMap { thread in
                guard let opPost = thread.opPost else { return nil }
                return ThreadSummary(
                    opPost: opPost,
                    postsCount: thread.postsCount,
                    filesCount: thread.filesCount
                )
            }
        }
    }

    private let client: DvachClient

    public init(client: DvachClient) {
        self.client = client
    }

    /// The whole board as a catalog, ordered by `sort`.
    public func catalog(
        board: String,
        sort: CatalogSort = .bumpOrder
    ) async throws(DvachError) -> CatalogPage {
        // The server can order by creation itself, which is cheaper and matches
        // its own paging.
        let response = try await client.catalog(board: board, byCreation: sort == .creationDate)
        return CatalogPage(
            board: response.board,
            threads: CatalogRepository.sort(response.threads, by: sort),
            bannerImagePath: response.bannerImage
        )
    }

    /// One page of the board, the way the site paginates it.
    public func page(board: String, page: Int) async throws(DvachError) -> IndexPage {
        let response = try await client.boardPage(board: board, page: page)
        return IndexPage(
            board: response.board,
            threads: response.threads,
            currentPage: response.currentPage,
            pageCount: max(response.pages.count, response.currentPage + 1),
            boardSpeed: response.boardSpeed
        )
    }

    // MARK: Ordering and filtering

    /// Orders threads, always keeping pinned ones at the top the way the site does.
    public static func sort(_ threads: [ThreadSummary], by sort: CatalogSort) -> [ThreadSummary] {
        let pinned = threads.filter(\.opPost.isSticky)
            .sorted { $0.opPost.stickyPriority > $1.opPost.stickyPriority }
        let rest = threads.filter { !$0.opPost.isSticky }

        let ordered: [ThreadSummary] = switch sort {
        case .bumpOrder:
            rest
        case .creationDate:
            rest.sorted { $0.opPost.timestamp > $1.opPost.timestamp }
        case .replyCount:
            rest.sorted { $0.postsCount > $1.postsCount }
        }
        return pinned + ordered
    }

    /// Local filtering for boards that do not support server-side search.
    /// Matches the subject, the comment text and the attachment names.
    public static func filter(_ threads: [ThreadSummary], matching query: String) -> [ThreadSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return threads }

        let parser = CommentHTMLParser()
        return threads.filter { thread in
            let post = thread.opPost
            if post.subject.localizedCaseInsensitiveContains(trimmed) { return true }
            if post.files.contains(where: { $0.fullName.localizedCaseInsensitiveContains(trimmed) }) {
                return true
            }
            // The comment is HTML, so it is parsed before matching; otherwise a
            // query such as "span" would match markup instead of text.
            let text = parser.parse(post.comment, inThread: post.num, onBoard: post.board).plainText
            return text.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
