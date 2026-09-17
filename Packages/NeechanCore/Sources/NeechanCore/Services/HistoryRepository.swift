import Foundation
import NeechanAPI
import SwiftData

/// Records and reads the threads the user has opened.
@ModelActor
public actor HistoryRepository {

    /// What the reader is willing to be shown. Read per query, so turning a
    /// restriction on takes effect without rebuilding this actor.
    private nonisolated let policyPort = ContentPolicyPort()

    /// - Parameter policy: read on every listing, never stored as a value.
    public init(modelContainer: ModelContainer, policy: @escaping ContentPolicyProvider) {
        self.init(modelContainer: modelContainer)
        policyPort.use(policy)
    }
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
                    key: key,
                    title: title,
                    visitedAt: date,
                    thumbnailPath: thumbnailPath
                )
            )
        }
        try modelContext.save()
    }

    /// Most recently visited threads first, on one imageboard.
    public func recent(site: Imageboard, limit: Int = 100) throws -> [HistoryItem] {
        let siteRaw = site.rawValue
        // Excluded in the query rather than afterwards, so the limit counts
        // threads the reader can actually open.
        let blocked = policyPort.policy.blockedCodes(on: site)
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate {
                $0.siteRaw == siteRaw && !blocked.contains($0.board)
            },
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(HistoryItem.init)
    }

    /// Case-insensitive title search, most recent first, on one imageboard.
    public func search(_ query: String, site: Imageboard, limit: Int = 100) throws -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recent(site: site, limit: limit) }

        let siteRaw = site.rawValue
        let blocked = policyPort.policy.blockedCodes(on: site)
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate {
                $0.siteRaw == siteRaw
                    && $0.title.localizedStandardContains(trimmed)
                    && !blocked.contains($0.board)
            },
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

    /// Forgets visits.
    ///
    /// - Parameter site: nil clears every imageboard's. The history screen
    ///   shows one site and passes that one, because clearing rows the reader
    ///   cannot see is not what the button says it does; the privacy screen
    ///   passes nil and says so.
    public func clear(site: Imageboard? = nil) throws {
        if let site {
            let siteRaw = site.rawValue
            try modelContext.delete(
                model: HistoryEntry.self,
                where: #Predicate { $0.siteRaw == siteRaw }
            )
        } else {
            try modelContext.delete(model: HistoryEntry.self)
        }
        try modelContext.save()
    }

    private func entry(for key: ThreadKey) throws -> HistoryEntry? {
        let site = key.site.rawValue
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate {
                $0.siteRaw == site && $0.board == board && $0.threadNum == threadNum
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension HistoryItem {
    init(_ entry: HistoryEntry) {
        self.init(
            key: entry.key,
            title: entry.title,
            visitedAt: entry.visitedAt,
            thumbnailPath: entry.thumbnailPath
        )
    }
}
