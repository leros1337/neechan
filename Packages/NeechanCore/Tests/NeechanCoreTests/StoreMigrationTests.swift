import Foundation
import NeechanAPI
import SwiftData
import Testing
@testable import NeechanCore

/// Opening a store written before there were two imageboards.
///
/// An in-memory container starts empty, so it cannot exercise this at all: each
/// test writes a real V1 store to its own file and reopens it under V2.
@Suite("Store migration")
struct StoreMigrationTests {
    /// A store of its own per test. swift-testing runs these in parallel, and
    /// two sharing one file would corrupt each other.
    private func temporaryStoreURL() -> URL {
        URL.temporaryDirectory.appending(path: "NeechanMigration-\(UUID().uuidString).store")
    }

    /// Writes the old shape and lets the container go out of scope, which is
    /// the only way SwiftData closes one.
    private func writeV1Store(at url: URL) throws {
        let schema = Schema(NeechanSchemaV1.models)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: nil,
            configurations: ModelConfiguration("Neechan", schema: schema, url: url)
        )
        let context = ModelContext(container)
        context.insert(NeechanSchemaV1.Favorite(board: "b", threadNum: 12345, title: "Тред"))
        context.insert(NeechanSchemaV1.FavoriteBoard(board: "b", name: "Бред"))
        context.insert(NeechanSchemaV1.HistoryEntry(board: "po", threadNum: 777, title: "Политика"))
        context.insert(NeechanSchemaV1.HiddenThread(board: "b", threadNum: 999, title: "Спам"))
        context.insert(NeechanSchemaV1.AutohideRule(pattern: "спам"))
        let watched = NeechanSchemaV1.WatchedThreadState(board: "b", threadNum: 12345)
        watched.unreadCount = 4
        context.insert(watched)
        try context.save()
    }

    @Test("a store written before there were two imageboards opens as 2ch's")
    func backfillsToDvach() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeV1Store(at: url)

        let container = try NeechanStore.makeContainer(at: url)
        let context = ModelContext(container)

        let favorites = try context.fetch(FetchDescriptor<Favorite>())
        #expect(favorites.count == 1)
        #expect(favorites.first?.site == .dvach)
        #expect(favorites.first?.title == "Тред")
        #expect(favorites.first?.key == ThreadKey(site: .dvach, board: "b", threadNum: 12345))

        let boards = try context.fetch(FetchDescriptor<FavoriteBoard>())
        #expect(boards.first?.site == .dvach)
        #expect(boards.first?.name == "Бред")

        let history = try context.fetch(FetchDescriptor<HistoryEntry>())
        #expect(history.first?.site == .dvach)

        let hidden = try context.fetch(FetchDescriptor<HiddenThread>())
        #expect(hidden.first?.site == .dvach)

        // The reading position survives, which is what a reader would notice.
        let watched = try context.fetch(FetchDescriptor<WatchedThreadState>())
        #expect(watched.first?.site == .dvach)
        #expect(watched.first?.unreadCount == 4)
    }

    /// The one that would fail before this version existed: `FavoriteBoard` was
    /// unique on the board code alone, so pinning the second site's `/b/` would
    /// have overwritten the first's rather than sitting beside it.
    @Test("pinning /b/ on one imageboard does not overwrite the other's")
    func favoriteBoardsNoLongerCollide() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeV1Store(at: url)

        let container = try NeechanStore.makeContainer(at: url)
        let context = ModelContext(container)
        context.insert(
            FavoriteBoard(board: BoardRef(site: .fourchan, code: "b"), name: "Random")
        )
        try context.save()

        let boards = try context.fetch(FetchDescriptor<FavoriteBoard>())
        #expect(boards.count == 2)
        #expect(Set(boards.map(\.site)) == [.dvach, .fourchan])
        #expect(boards.filter { $0.site == .dvach }.first?.name == "Бред")
    }

    @Test("two imageboards' /b/12345 are two different threads")
    func threadsNoLongerCollide() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeV1Store(at: url)

        let container = try NeechanStore.makeContainer(at: url)
        let context = ModelContext(container)
        context.insert(
            Favorite(
                key: ThreadKey(site: .fourchan, board: "b", threadNum: 12345),
                title: "Another board entirely"
            )
        )
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Favorite>()).count == 2)
    }

    /// A rule is what the reader wants hidden, not a record of something they
    /// did on a site, so it is deliberately *not* narrowed to 2ch on upgrade.
    @Test("an autohide rule carried over applies to every imageboard")
    func rulesStaySiteBlind() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeV1Store(at: url)

        let container = try NeechanStore.makeContainer(at: url)
        let context = ModelContext(container)

        let rule = try #require(try context.fetch(FetchDescriptor<AutohideRule>()).first)
        #expect(rule.sitesRaw.isEmpty)
        #expect(rule.value.sites.isEmpty)
        #expect(rule.value.appliesTo(thread: ThreadKey(site: .dvach, board: "b", threadNum: 1)))
        #expect(rule.value.appliesTo(thread: ThreadKey(site: .fourchan, board: "b", threadNum: 1)))
    }

    @Test("a store already on the current version opens unchanged")
    func reopeningIsStable() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeV1Store(at: url)

        _ = try NeechanStore.makeContainer(at: url)
        let container = try NeechanStore.makeContainer(at: url)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Favorite>()).count == 1)
    }
}
