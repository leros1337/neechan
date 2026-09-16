import Foundation
import SwiftData

/// Records and reads the threads the user has opened.
@ModelActor
public actor HistoryRepository {
    /// Mirrors the "remember history" preference. When off, visits are dropped
    /// rather than written and then hidden.
    private var isRecordingEnabled = true

    public func setRecordingEnabled(_ enabled: Bool) {
        isRecordingEnabled = enabled
    }

    /// Notes that a thread was opened. Visiting a thread again moves it to the
    /// top rather than adding a second row.
    public func recordVisit(
        _ key: ThreadKey,
        title: String,
        thumbnailPath: String? = nil,
        at date: Date = .now
    ) throws {
        guard isRecordingEnabled else { return }

        if let existing = try entry(for: key) {
            existing.title = title
            existing.visitedAt = date
            if let thumbnailPath { existing.thumbnailPath = thumbnailPath }
        } else {
            modelContext.insert(
                HistoryEntry(
                    board: key.board,
                    threadNum: key.threadNum,
                    title: title,
                    visitedAt: date,
                    thumbnailPath: thumbnailPath
                )
            )
        }
        try modelContext.save()
    }

    /// Most recently visited threads first.
    public func recent(limit: Int = 100) throws -> [HistoryItem] {
        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(HistoryItem.init)
    }

    /// Case-insensitive title search, most recent first.
    public func search(_ query: String, limit: Int = 100) throws -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recent(limit: limit) }

        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.title.localizedStandardContains(trimmed) },
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(HistoryItem.init)
    }

    public func remove(_ key: ThreadKey) throws {
        guard let existing = try entry(for: key) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    public func clear() throws {
        try modelContext.delete(model: HistoryEntry.self)
        try modelContext.save()
    }

    private func entry(for key: ThreadKey) throws -> HistoryEntry? {
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.board == board && $0.threadNum == threadNum }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension HistoryItem {
    init(_ entry: HistoryEntry) {
        self.init(
            key: ThreadKey(board: entry.board, threadNum: entry.threadNum),
            title: entry.title,
            visitedAt: entry.visitedAt,
            thumbnailPath: entry.thumbnailPath
        )
    }
}
