import Foundation
import NeechanAPI
import NeechanSettings
import SwiftData

/// Exports and imports the reader's own data.
@ModelActor
public actor BackupService {
    /// Gathers everything into one document.
    public func export(settings: [String: String]) throws -> NeechanBackup {
        NeechanBackup(
            favorites: try modelContext.fetch(FetchDescriptor<Favorite>()).map {
                NeechanBackup.FavoriteEntry(
                    board: $0.board,
                    threadNum: $0.threadNum,
                    title: $0.title,
                    customTitle: $0.customTitle,
                    createdAt: $0.createdAt,
                    isWatched: $0.isWatched,
                    site: $0.siteRaw
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
            settings: settings
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
                createdAt: entry.createdAt
            )
            favorite.customTitle = entry.customTitle
            favorite.isWatched = entry.isWatched
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

        public var total: Int {
            favorites + favoriteBoards + history + autohideRules + hiddenThreads
        }
    }
}
