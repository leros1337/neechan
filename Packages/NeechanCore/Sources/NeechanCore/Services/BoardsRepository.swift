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
    /// Matched by the site's own label. There are dozens of these and they are
    /// buried in the middle of the directory, so the app offers them as their
    /// own list.
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
    private var cached: [Board]?

    public init(client: DvachClient) {
        self.client = client
    }

    /// - Parameter forceRefresh: skip the cache, for pull to refresh.
    public func boards(forceRefresh: Bool = false) async throws(DvachError) -> [Board] {
        if !forceRefresh, let cached { return cached }
        let boards = try await client.boards()
        cached = boards
        return boards
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
    public func invalidate() {
        cached = nil
    }
}
