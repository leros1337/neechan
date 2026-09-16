import Foundation
import NeechanSettings
import SwiftData

/// A favourite thread as a value, with whatever the watcher last saw.
public struct FavoriteItem: Sendable, Hashable, Identifiable {
    public let key: ThreadKey
    public let title: String
    public let createdAt: Date
    public let isWatched: Bool
    public let thumbnailPath: String?

    public let unreadCount: Int
    public let isDeleted: Bool
    public let isClosed: Bool

    public var id: ThreadKey { key }

    public init(
        key: ThreadKey,
        title: String,
        createdAt: Date,
        isWatched: Bool,
        thumbnailPath: String?,
        unreadCount: Int = 0,
        isDeleted: Bool = false,
        isClosed: Bool = false
    ) {
        self.key = key
        self.title = title
        self.createdAt = createdAt
        self.isWatched = isWatched
        self.thumbnailPath = thumbnailPath
        self.unreadCount = unreadCount
        self.isDeleted = isDeleted
        self.isClosed = isClosed
    }
}

/// Threads and boards the reader keeps.
@ModelActor
public actor FavoritesRepository {
    // MARK: Threads

    @discardableResult
    public func add(
        _ key: ThreadKey,
        title: String,
        thumbnailPath: String? = nil,
        watch: Bool = true
    ) throws -> Bool {
        guard try storedFavorite(key) == nil else { return false }

        let favorite = Favorite(
            board: key.board,
            threadNum: key.threadNum,
            title: title,
            opThumbnailPath: thumbnailPath
        )
        favorite.isWatched = watch
        modelContext.insert(favorite)
        try modelContext.save()
        return true
    }

    public func remove(_ key: ThreadKey) throws {
        guard let stored = try storedFavorite(key) else { return }
        modelContext.delete(stored)
        try modelContext.save()
    }

    public func isFavorite(_ key: ThreadKey) throws -> Bool {
        try storedFavorite(key) != nil
    }

    /// Adds or removes, and reports which it did.
    @discardableResult
    public func toggle(_ key: ThreadKey, title: String, thumbnailPath: String? = nil) throws -> Bool {
        if try isFavorite(key) {
            try remove(key)
            return false
        }
        try add(key, title: title, thumbnailPath: thumbnailPath)
        return true
    }

    public func rename(_ key: ThreadKey, to title: String?) throws {
        guard let stored = try storedFavorite(key) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try modelContext.save()
    }

    public func setWatched(_ watched: Bool, for key: ThreadKey) throws {
        guard let stored = try storedFavorite(key) else { return }
        stored.isWatched = watched
        try modelContext.save()
    }

    /// Favourites in the order the reader asked for, each carrying what the
    /// watcher last saw.
    public func favorites(order: FavoritesOrder = .newestFirst) throws -> [FavoriteItem] {
        let stored = try modelContext.fetch(FetchDescriptor<Favorite>())
        let states = try watchedStates()

        let items = stored.map { favorite -> FavoriteItem in
            let key = ThreadKey(board: favorite.board, threadNum: favorite.threadNum)
            let state = states[key]
            return FavoriteItem(
                key: key,
                title: favorite.displayTitle,
                createdAt: favorite.createdAt,
                isWatched: favorite.isWatched,
                thumbnailPath: favorite.opThumbnailPath,
                unreadCount: state?.unreadCount ?? 0,
                isDeleted: state?.isThreadDeleted ?? false,
                isClosed: state?.isClosed ?? false
            )
        }
        return sort(items, by: order)
    }

    /// Threads the watcher should poll.
    public func watchedKeys() throws -> [ThreadKey] {
        try modelContext.fetch(FetchDescriptor<Favorite>())
            .filter(\.isWatched)
            .map { ThreadKey(board: $0.board, threadNum: $0.threadNum) }
    }

    /// Drops favourites whose threads the watcher found gone.
    public func removeDeleted() throws {
        let states = try watchedStates()
        for favorite in try modelContext.fetch(FetchDescriptor<Favorite>()) {
            let key = ThreadKey(board: favorite.board, threadNum: favorite.threadNum)
            if states[key]?.isThreadDeleted == true {
                modelContext.delete(favorite)
            }
        }
        try modelContext.save()
    }

    // MARK: Boards

    @discardableResult
    public func addBoard(_ board: String, name: String) throws -> Bool {
        guard try storedBoard(board) == nil else { return false }
        modelContext.insert(FavoriteBoard(board: board, name: name))
        try modelContext.save()
        return true
    }

    public func removeBoard(_ board: String) throws {
        guard let stored = try storedBoard(board) else { return }
        modelContext.delete(stored)
        try modelContext.save()
    }

    public func isFavoriteBoard(_ board: String) throws -> Bool {
        try storedBoard(board) != nil
    }

    @discardableResult
    public func toggleBoard(_ board: String, name: String) throws -> Bool {
        if try isFavoriteBoard(board) {
            try removeBoard(board)
            return false
        }
        try addBoard(board, name: name)
        return true
    }

    public func favoriteBoards() throws -> [(board: String, name: String)] {
        try modelContext.fetch(
            FetchDescriptor<FavoriteBoard>(sortBy: [SortDescriptor(\.createdAt)])
        )
        .map { ($0.board, $0.name) }
    }

    // MARK: Internals

    private func sort(_ items: [FavoriteItem], by order: FavoritesOrder) -> [FavoriteItem] {
        switch order {
        case .newestFirst:
            items.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            items.sorted { $0.createdAt < $1.createdAt }
        case .title:
            items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .unreadFirst:
            // Threads with something new, most first, then the rest by date.
            items.sorted {
                if $0.unreadCount != $1.unreadCount { return $0.unreadCount > $1.unreadCount }
                return $0.createdAt > $1.createdAt
            }
        }
    }

    private func watchedStates() throws -> [ThreadKey: WatchedThreadState] {
        let states = try modelContext.fetch(FetchDescriptor<WatchedThreadState>())
        return Dictionary(
            states.map { (ThreadKey(board: $0.board, threadNum: $0.threadNum), $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    private func storedFavorite(_ key: ThreadKey) throws -> Favorite? {
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<Favorite>(
            predicate: #Predicate { $0.board == board && $0.threadNum == threadNum }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedBoard(_ board: String) throws -> FavoriteBoard? {
        var descriptor = FetchDescriptor<FavoriteBoard>(
            predicate: #Predicate { $0.board == board }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
