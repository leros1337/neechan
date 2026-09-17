import Foundation
import NeechanAPI

/// The board list, fetched once and kept.
///
/// The list changes perhaps a few times a year, so it is cached for the life of
/// the session and only refetched when the user pulls to refresh.
public actor BoardsRepository {
    /// Boards sharing a category heading, in the order the server listed them.
    /// The category the site files reader-created boards under.
    ///
    /// Matched by the site's own label, which is why it is not localized: it is
    /// compared against what the server sends, not shown. There are dozens of
    /// these and they are buried in the middle of the directory, so the app
    /// offers them as their own list.
    ///
    /// Nil on an imageboard that has no such thing.
    public nonisolated static func userBoardCategory(for site: Imageboard) -> String? {
        switch site {
        case .dvach: "Пользовательские"
        case .fourchan: nil
        }
    }

    /// The 2ch label, kept for the call sites that predate a second site.
    public static let userBoardCategory = "Пользовательские"

    public nonisolated static func isUserBoard(_ board: Board) -> Bool {
        board.category == userBoardCategory
    }

    /// The reader-created boards, in the order the site lists them.
    public nonisolated static func userBoards(in boards: [Board]) -> [Board] {
        boards.filter(isUserBoard)
    }

    public struct Category: Sendable, Hashable, Identifiable {
        public let name: String
        public let boards: [Board]
        public var id: String { name }

        public init(name: String, boards: [Board]) {
            self.name = name
            self.boards = boards
        }
    }

    private let client: DvachClient
    private let site: SiteProvider
    /// Board lists, per imageboard.
    ///
    /// Keyed by site rather than held as one list: a single slot answered with
    /// whichever site was asked last, so a switch showed the old site's boards
    /// until something happened to clear it. Keying it means the cache cannot
    /// give a wrong answer at all, rather than relying on being emptied at the
    /// right moment.
    private var cached: [Imageboard: [Board]] = [:]

    private let policy: ContentPolicyProvider

    public init(
        client: DvachClient,
        site: @escaping SiteProvider,
        policy: @escaping ContentPolicyProvider = { .unrestricted }
    ) {
        self.client = client
        self.site = site
        self.policy = policy
    }

    /// - Parameter forceRefresh: skip the cache, for pull to refresh.
    ///
    /// The reader's restrictions are applied on the way out, never on the way
    /// in: the cache holds the site's whole directory, so turning a restriction
    /// on or off changes what this returns on the very next call without
    /// touching the network. `categories`, `board(id:)` and `search` all come
    /// through here, so this is the only place the filter is needed.
    public func boards(forceRefresh: Bool = false) async throws(DvachError) -> [Board] {
        let site = site().site
        if !forceRefresh, let cached = cached[site] {
            return policy().filter(cached, on: site)
        }
        let boards = try await client.boards()
        cached[site] = boards
        // Which boards are user-made is only knowable from a directory, and on
        // 2ch every one of them is restricted. Told here so a board created
        // after this app shipped is covered by code alone elsewhere.
        MatureBoards.learn(
            userBoardCodes: Set(
                boards.filter { $0.category == Self.userBoardCategory(for: site) }.map(\.id)
            ),
            on: site
        )
        return policy().filter(boards, on: site)
    }

    /// Boards grouped under their category headings.
    public func categories(forceRefresh: Bool = false) async throws(DvachError) -> [Category] {
        let boards = try await boards(forceRefresh: forceRefresh)

        var order: [String] = []
        var grouped: [String: [Board]] = [:]
        for board in boards {
            let name = board.category.isEmpty ? "" : board.category
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(board)
        }
        return order.map { Category(name: $0, boards: grouped[$0] ?? []) }
    }

    public func board(id: String) async throws(DvachError) -> Board? {
        try await boards().first { $0.id == id }
    }

    /// Matches a board by code, name or category. An empty query matches all.
    public func search(_ query: String) async throws(DvachError) -> [Board] {
        let all = try await boards()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }

        return all.filter { board in
            board.id.localizedCaseInsensitiveContains(trimmed)
                || board.name.localizedCaseInsensitiveContains(trimmed)
                || board.category.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Drops the cache, for example after switching mirror.
    /// Forgets every site's board list.
    public func invalidate() {
        cached.removeAll()
    }
}
