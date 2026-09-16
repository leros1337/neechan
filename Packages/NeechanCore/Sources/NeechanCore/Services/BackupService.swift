import Foundation
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
                    isWatched: $0.isWatched
                )
            },
            favoriteBoards: try modelContext.fetch(FetchDescriptor<FavoriteBoard>()).map(\.board),
            history: try modelContext.fetch(FetchDescriptor<HistoryEntry>()).map {
                NeechanBackup.HistoryEntryRecord(
                    board: $0.board,
                    threadNum: $0.threadNum,
                    title: $0.title,
                    visitedAt: $0.visitedAt
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
                    appliesToOriginalPostOnly: $0.appliesToOriginalPostOnly,
                    appliesToSagedOnly: $0.appliesToSagedOnly,
                    isEnabled: $0.isEnabled
                )
            },
            hiddenThreads: try modelContext.fetch(FetchDescriptor<HiddenThread>()).map {
                NeechanBackup.HiddenThreadEntry(
                    board: $0.board, threadNum: $0.threadNum, title: $0.title
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

        let existingFavorites = Set(
            try modelContext.fetch(FetchDescriptor<Favorite>()).map { "\($0.board)/\($0.threadNum)" }
        )
        for entry in backup.favorites where !existingFavorites.contains("\(entry.board)/\(entry.threadNum)") {
            let favorite = Favorite(
                board: entry.board,
                threadNum: entry.threadNum,
                title: entry.title,
                createdAt: entry.createdAt
            )
            favorite.customTitle = entry.customTitle
            favorite.isWatched = entry.isWatched
            modelContext.insert(favorite)
            summary.favorites += 1
        }

        let existingBoards = Set(
            try modelContext.fetch(FetchDescriptor<FavoriteBoard>()).map(\.board)
        )
        for board in backup.favoriteBoards where !existingBoards.contains(board) {
            modelContext.insert(FavoriteBoard(board: board, name: board))
            summary.favoriteBoards += 1
        }

        let existingHistory = Set(
            try modelContext.fetch(FetchDescriptor<HistoryEntry>()).map { "\($0.board)/\($0.threadNum)" }
        )
        for entry in backup.history where !existingHistory.contains("\(entry.board)/\(entry.threadNum)") {
            modelContext.insert(
                HistoryEntry(
                    board: entry.board,
                    threadNum: entry.threadNum,
                    title: entry.title,
                    visitedAt: entry.visitedAt
                )
            )
            summary.history += 1
        }

        // Rules are matched on their pattern and fields, since they carry no
        // identity the exporting device and this one would agree on.
        let existingRules = Set(
            try modelContext.fetch(FetchDescriptor<AutohideRule>()).map(\.pattern)
        )
        for entry in backup.autohideRules where !existingRules.contains(entry.pattern) {
            var value = AutohideRuleValue(
                pattern: entry.pattern,
                isRegularExpression: entry.isRegularExpression,
                matchesSubject: entry.matchesSubject,
                matchesComment: entry.matchesComment,
                matchesName: entry.matchesName,
                matchesFileName: entry.matchesFileName,
                boards: Set(entry.boards),
                appliesToOriginalPostOnly: entry.appliesToOriginalPostOnly,
                appliesToSagedOnly: entry.appliesToSagedOnly,
                isEnabled: entry.isEnabled
            )
            value.id = UUID()
            modelContext.insert(AutohideRule(value: value))
            summary.autohideRules += 1
        }

        let existingHidden = Set(
            try modelContext.fetch(FetchDescriptor<HiddenThread>()).map { "\($0.board)/\($0.threadNum)" }
        )
        for entry in backup.hiddenThreads where !existingHidden.contains("\(entry.board)/\(entry.threadNum)") {
            modelContext.insert(
                HiddenThread(board: entry.board, threadNum: entry.threadNum, title: entry.title)
            )
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
