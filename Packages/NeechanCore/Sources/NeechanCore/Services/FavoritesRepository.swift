import Foundation
import NeechanAPI
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

    /// What the reader is willing to be shown. Read per query, so turning a
    /// restriction on takes effect without rebuilding this actor.
    private nonisolated let policyPort = ContentPolicyPort()

    /// - Parameter policy: read on every listing, never stored as a value.
    public init(modelContainer: ModelContainer, policy: @escaping ContentPolicyProvider) {
        self.init(modelContainer: modelContainer)
        policyPort.use(policy)
    }
    // MARK: Threads

    @discardableResult
    public func add(
        _ key: ThreadKey,
        title: String,
        thumbnailPath: String? = nil,
        watch: Bool = true
    ) throws -> Bool {
        guard try storedFavorite(key) == nil else { return false }

        let favorite = Favorite(key: key, title: title, opThumbnailPath: thumbnailPath)
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
    public func favorites(
        site: Imageboard,
        order: FavoritesOrder = .newestFirst
    ) throws -> [FavoriteItem] {
        let siteRaw = site.rawValue
        let stored = try modelContext.fetch(
            FetchDescriptor<Favorite>(predicate: #Predicate { $0.siteRaw == siteRaw })
        )
        let states = try watchedStates(site: site)

        let policy = policyPort.policy
        let items = stored.filter { policy.allows($0.key) }.map { favorite -> FavoriteItem in
            let key = favorite.key
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
    public func watchedKeys(site: Imageboard) throws -> [ThreadKey] {
        let siteRaw = site.rawValue
        return try modelContext.fetch(
            FetchDescriptor<Favorite>(predicate: #Predicate { $0.siteRaw == siteRaw })
        )
        .filter(\.isWatched)
        .map(\.key)
        // Also the reason no notification can name a restricted board: the
        // watcher's whole poll list comes from here.
        .filter(policyPort.policy.allows)
    }

    /// Drops favourites whose threads the watcher found gone.
    public func removeDeleted(site: Imageboard) throws {
        let siteRaw = site.rawValue
        let states = try watchedStates(site: site)
        for favorite in try modelContext.fetch(
            FetchDescriptor<Favorite>(predicate: #Predicate { $0.siteRaw == siteRaw })
        ) where states[favorite.key]?.isThreadDeleted == true {
            modelContext.delete(favorite)
        }
        try modelContext.save()
    }

    // MARK: Boards

    @discardableResult
    public func addBoard(_ board: BoardRef, name: String) throws -> Bool {
        guard try storedBoard(board) == nil else { return false }
        modelContext.insert(FavoriteBoard(board: board, name: name))
        try modelContext.save()
        return true
    }

    public func removeBoard(_ board: BoardRef) throws {
        guard let stored = try storedBoard(board) else { return }
        modelContext.delete(stored)
        try modelContext.save()
    }

    public func isFavoriteBoard(_ board: BoardRef) throws -> Bool {
        try storedBoard(board) != nil
    }

    @discardableResult
    public func toggleBoard(_ board: BoardRef, name: String) throws -> Bool {
        if try isFavoriteBoard(board) {
            try removeBoard(board)
            return false
        }
        try addBoard(board, name: name)
        return true
    }

    public func favoriteBoards(site: Imageboard) throws -> [(board: String, name: String)] {
        let siteRaw = site.rawValue
        return try modelContext.fetch(
            FetchDescriptor<FavoriteBoard>(
                predicate: #Predicate { $0.siteRaw == siteRaw },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
        .filter { policyPort.policy.allows(code: $0.board, on: site) }
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

    /// The watcher's view of one site's threads, keyed the way favourites are.
    ///
    /// Scoped to the site because the key carries one: an unscoped fetch would
    /// look up a 2ch key against a dictionary holding both sites' rows and miss,
    /// which shows as every favourite reporting nothing unread.
    private func watchedStates(site: Imageboard) throws -> [ThreadKey: WatchedThreadState] {
        let siteRaw = site.rawValue
        let states = try modelContext.fetch(
            FetchDescriptor<WatchedThreadState>(predicate: #Predicate { $0.siteRaw == siteRaw })
        )
        return Dictionary(
            states.map { ($0.key, $0) },
            // Two rows for one key should be impossible under the uniqueness
            // constraint; if it ever happens, the freshest poll is the one
            // worth believing rather than whatever the fetch returned last.
            uniquingKeysWith: { $0.lastPolledAt >= $1.lastPolledAt ? $0 : $1 }
        )
    }

    private func storedFavorite(_ key: ThreadKey) throws -> Favorite? {
        let site = key.site.rawValue
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<Favorite>(
            predicate: #Predicate {
                $0.siteRaw == site && $0.board == board && $0.threadNum == threadNum
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedBoard(_ board: BoardRef) throws -> FavoriteBoard? {
        let site = board.site.rawValue
        let code = board.code
        var descriptor = FetchDescriptor<FavoriteBoard>(
            predicate: #Predicate { $0.siteRaw == site && $0.board == code }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
