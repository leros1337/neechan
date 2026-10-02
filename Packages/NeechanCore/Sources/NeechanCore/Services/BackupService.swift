import Foundation
import NeechanAPI
import NeechanSettings
import SwiftData

/// Exports and imports the reader's own data.
@ModelActor
public actor BackupService {
    /// Gathers everything into one document.
    ///
    /// - Parameters:
    ///   - preferences: the settings, which live in `AppSettings` rather than
    ///     here and so are handed in.
    ///   - statistics: the usage counters, likewise.
    public func export(
        settings: [String: String] = [:],
        preferences: PreferencesBackup? = nil,
        statistics: UsageStatistics? = nil
    ) throws -> NeechanBackup {
        NeechanBackup(
            favorites: try modelContext.fetch(FetchDescriptor<Favorite>()).map {
                NeechanBackup.FavoriteEntry(
                    board: $0.board,
                    threadNum: $0.threadNum,
                    title: $0.title,
                    customTitle: $0.customTitle,
                    createdAt: $0.createdAt,
                    isWatched: $0.isWatched,
                    site: $0.siteRaw,
                    sortOrder: $0.sortOrder,
                    opThumbnailPath: $0.opThumbnailPath
                )
            },
            // Both shapes: the flat list keeps an older build able to read the
            // 2ch pins, the entries carry the site.
            favoriteBoards: try modelContext.fetch(FetchDescriptor<FavoriteBoard>())
                .filter { $0.site == .dvach }
                .map(\.board),
            favoriteBoardEntries: try modelContext.fetch(FetchDescriptor<FavoriteBoard>()).map {
                NeechanBackup.FavoriteBoardEntry(
                    board: $0.board, name: $0.name, site: $0.siteRaw
                )
            },
            history: try modelContext.fetch(FetchDescriptor<HistoryEntry>()).map {
                NeechanBackup.HistoryEntryRecord(
                    board: $0.board,
                    threadNum: $0.threadNum,
                    title: $0.title,
                    visitedAt: $0.visitedAt,
                    site: $0.siteRaw
                )
            },
            autohideRules: try modelContext.fetch(FetchDescriptor<AutohideRule>()).map {
                NeechanBackup.AutohideEntry(
                    pattern: $0.pattern,
                    isRegularExpression: $0.isRegularExpression,
                    matchesSubject: $0.matchesSubject,
                    matchesComment: $0.matchesComment,
                    matchesName: $0.matchesName,
                    matchesFileName: $0.matchesFileName,
                    boards: $0.boards,
                    sites: $0.sitesRaw,
                    appliesToOriginalPostOnly: $0.appliesToOriginalPostOnly,
                    appliesToSagedOnly: $0.appliesToSagedOnly,
                    isEnabled: $0.isEnabled
                )
            },
            hiddenThreads: try modelContext.fetch(FetchDescriptor<HiddenThread>()).map {
                NeechanBackup.HiddenThreadEntry(
                    board: $0.board, threadNum: $0.threadNum, title: $0.title, site: $0.siteRaw
                )
            },
            settings: settings,
            preferences: preferences,
            statistics: statistics,
            ownPosts: try modelContext.fetch(FetchDescriptor<OwnPost>()).map {
                NeechanBackup.OwnPostEntry(
                    board: $0.board, threadNum: $0.threadNum, postNum: $0.postNum,
                    createdAt: $0.createdAt, site: $0.siteRaw
                )
            },
            hiddenPostRules: try modelContext.fetch(FetchDescriptor<HiddenPostRule>()).map {
                NeechanBackup.HiddenPostRuleEntry(
                    board: $0.board, threadNum: $0.threadNum, kind: $0.kindRaw,
                    postNum: $0.postNum, name: $0.name, similarText: $0.similarText,
                    createdAt: $0.createdAt, site: $0.siteRaw
                )
            },
            watchedThreads: try modelContext.fetch(FetchDescriptor<WatchedThreadState>()).map {
                NeechanBackup.WatchedThreadEntry(
                    board: $0.board, threadNum: $0.threadNum, site: $0.siteRaw,
                    lastReadPostNum: $0.lastReadPostNum,
                    lastKnownMaxNum: $0.lastKnownMaxNum,
                    lastKnownPostsCount: $0.lastKnownPostsCount,
                    unreadCount: $0.unreadCount,
                    readPostsCount: $0.readPostsCount,
                    isThreadDeleted: $0.isThreadDeleted,
                    isClosed: $0.isClosed,
                    isArchived: $0.isArchived,
                    lastPolledAt: $0.lastPolledAt,
                    scrollAnchorPostNum: $0.scrollAnchorPostNum,
                    scrollAnchorOffset: $0.scrollAnchorOffset
                )
            },
            themes: try modelContext.fetch(FetchDescriptor<StoredTheme>()).map {
                NeechanBackup.ThemeEntry(
                    themeID: $0.themeID, name: $0.name, createdAt: $0.createdAt, payload: $0.payload
                )
            }
        )
    }

    /// Merges a backup into whatever is already here.
    ///
    /// Merging rather than replacing: importing on a device already in use must
    /// not throw away what is on it.
    @discardableResult
    public func `import`(_ backup: NeechanBackup) throws -> ImportSummary {
        var summary = ImportSummary()

        // Keys carry the imageboard, or importing a 4chan /b/1 onto a device
        // holding a 2ch /b/1 would silently drop it.
        let existingFavorites = Set(
            try modelContext.fetch(FetchDescriptor<Favorite>()).map(\.key)
        )
        for entry in backup.favorites where !existingFavorites.contains(entry.key) {
            let favorite = Favorite(
                key: entry.key,
                title: entry.title,
                createdAt: entry.createdAt,
                opThumbnailPath: entry.opThumbnailPath
            )
            favorite.customTitle = entry.customTitle
            favorite.isWatched = entry.isWatched
            if let sortOrder = entry.sortOrder { favorite.sortOrder = sortOrder }
            modelContext.insert(favorite)
            summary.favorites += 1
        }

        let existingBoards = Set(
            try modelContext.fetch(FetchDescriptor<FavoriteBoard>()).map(\.ref)
        )
        // Version 2 files carry the site on each entry; older ones have only
        // the flat list, which was 2ch's.
        let boardEntries = backup.favoriteBoardEntries
            ?? backup.favoriteBoards.map {
                NeechanBackup.FavoriteBoardEntry(board: $0, name: $0, site: nil)
            }
        for entry in boardEntries where !existingBoards.contains(entry.ref) {
            modelContext.insert(FavoriteBoard(board: entry.ref, name: entry.name))
            summary.favoriteBoards += 1
        }

        let existingHistory = Set(
            try modelContext.fetch(FetchDescriptor<HistoryEntry>()).map(\.key)
        )
        for entry in backup.history where !existingHistory.contains(entry.key) {
            modelContext.insert(
                HistoryEntry(key: entry.key, title: entry.title, visitedAt: entry.visitedAt)
            )
            summary.history += 1
        }

        // Rules are matched on their pattern and fields, since they carry no
        // identity the exporting device and this one would agree on.
        // Keyed on the pattern *and* its scope: two rules with the same text
        // scoped to different imageboards are two rules.
        let existingRules = Set(
            try modelContext.fetch(FetchDescriptor<AutohideRule>())
                .map { "\($0.pattern)|\($0.sitesRaw.sorted().joined(separator: ","))" }
        )
        for entry in backup.autohideRules
        where !existingRules.contains(
            "\(entry.pattern)|\((entry.sites ?? []).sorted().joined(separator: ","))"
        ) {
            var value = AutohideRuleValue(
                pattern: entry.pattern,
                isRegularExpression: entry.isRegularExpression,
                matchesSubject: entry.matchesSubject,
                matchesComment: entry.matchesComment,
                matchesName: entry.matchesName,
                matchesFileName: entry.matchesFileName,
                boards: Set(entry.boards),
                sites: Set((entry.sites ?? []).compactMap(Imageboard.init(rawValue:))),
                appliesToOriginalPostOnly: entry.appliesToOriginalPostOnly,
                appliesToSagedOnly: entry.appliesToSagedOnly,
                isEnabled: entry.isEnabled
            )
            value.id = UUID()
            modelContext.insert(AutohideRule(value: value))
            summary.autohideRules += 1
        }

        let existingHidden = Set(
            try modelContext.fetch(FetchDescriptor<HiddenThread>()).map(\.key)
        )
        for entry in backup.hiddenThreads where !existingHidden.contains(entry.key) {
            modelContext.insert(HiddenThread(key: entry.key, title: entry.title))
            summary.hiddenThreads += 1
        }

        // A post is the reader's by its number on its board: the same number
        // in another thread of the board would be the same post.
        var existingOwn = Set(
            try modelContext.fetch(FetchDescriptor<OwnPost>())
                .map { "\($0.siteRaw)|\($0.board)|\($0.postNum)" }
        )
        for entry in backup.ownPosts ?? [] {
            let identity = "\(entry.key.site.rawValue)|\(entry.board)|\(entry.postNum)"
            guard existingOwn.insert(identity).inserted else { continue }
            modelContext.insert(OwnPost(key: entry.key, postNum: entry.postNum, createdAt: entry.createdAt))
            summary.ownPosts += 1
        }

        // A hidden post has no identity of its own, so it is matched on all of
        // what it says.
        var existingPostRules = Set(
            try modelContext.fetch(FetchDescriptor<HiddenPostRule>()).compactMap { stored in
                stored.rule.map {
                    HiddenPostIdentity(
                        key: ThreadKey(site: stored.site, board: stored.board, threadNum: stored.threadNum),
                        rule: $0
                    )
                }
            }
        )
        for entry in backup.hiddenPostRules ?? [] {
            // A kind this build does not know is left out rather than kept as
            // a rule that hides nothing.
            guard let rule = entry.rule,
                  existingPostRules.insert(HiddenPostIdentity(key: entry.key, rule: rule)).inserted
            else { continue }
            modelContext.insert(HiddenPostRule(key: entry.key, rule: rule, createdAt: entry.createdAt))
            summary.hiddenPostRules += 1
        }

        // Only for a thread this device knows nothing about. Where it has a
        // state of its own, that one has seen the thread more recently than a
        // file made some time ago.
        var existingWatched = Set(
            try modelContext.fetch(FetchDescriptor<WatchedThreadState>()).map(\.key)
        )
        for entry in backup.watchedThreads ?? [] {
            guard existingWatched.insert(entry.key).inserted else { continue }
            let state = WatchedThreadState(key: entry.key)
            state.lastReadPostNum = entry.lastReadPostNum
            state.lastKnownMaxNum = entry.lastKnownMaxNum
            state.lastKnownPostsCount = entry.lastKnownPostsCount
            state.unreadCount = entry.unreadCount
            state.readPostsCount = entry.readPostsCount
            state.isThreadDeleted = entry.isThreadDeleted
            state.isClosed = entry.isClosed
            state.isArchived = entry.isArchived
            state.lastPolledAt = entry.lastPolledAt
            state.scrollAnchorPostNum = entry.scrollAnchorPostNum
            state.scrollAnchorOffset = entry.scrollAnchorOffset
            modelContext.insert(state)
            summary.watchedThreads += 1
        }

        var existingThemes = Set(
            try modelContext.fetch(FetchDescriptor<StoredTheme>()).map(\.themeID)
        )
        for entry in backup.themes ?? [] {
            guard existingThemes.insert(entry.themeID).inserted else { continue }
            modelContext.insert(
                StoredTheme(
                    themeID: entry.themeID, name: entry.name,
                    payload: entry.payload, createdAt: entry.createdAt
                )
            )
            summary.themes += 1
        }

        try modelContext.save()
        return summary
    }

    /// What an import added.
    public struct ImportSummary: Sendable, Equatable {
        public var favorites = 0
        public var favoriteBoards = 0
        public var history = 0
        public var autohideRules = 0
        public var hiddenThreads = 0
        public var ownPosts = 0
        public var hiddenPostRules = 0
        public var watchedThreads = 0
        public var themes = 0

        public var total: Int {
            favorites + favoriteBoards + history + autohideRules + hiddenThreads
                + ownPosts + hiddenPostRules + watchedThreads + themes
        }
    }

    /// What makes two hidden posts the same one.
    private struct HiddenPostIdentity: Hashable {
        let key: ThreadKey
        let rule: LocalHideRule
    }
}
