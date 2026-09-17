import Foundation
import NeechanAPI
import SwiftData
import Testing
@testable import NeechanCore

/// Opening a store written before there were two imageboards.
///
/// An in-memory container starts empty, so it cannot exercise this at all: each
/// test takes a copy of a real V1 store and opens it under the current schema.
///
/// The store is a committed fixture rather than something written here, and it
/// has to be. V1 and V2 give their entities the same names on purpose — that is
/// what lets SwiftData match them across the migration — so a process holding
/// both schemas has two descriptions claiming one entity, and whichever was
/// registered last wins. Writing a V1 store while another suite happened to be
/// building a V2 container aborted the whole test run with
/// `HistoryEntry is not key value coding-compliant for the key "siteRaw"`.
/// Reading a file written earlier needs no V1 container at all.
@Suite("Store migration")
struct StoreMigrationTests {
    /// A copy of the fixture, in a directory of its own.
    ///
    /// Copied because opening it migrates it in place, and swift-testing runs
    /// these in parallel: they would otherwise migrate one file five times.
    private func v1StoreCopy() throws -> URL {
        let fixture = try #require(
            Bundle.module.url(forResource: "neechan-v1", withExtension: "store", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "neechan-v1", withExtension: "store"),
            "the V1 store fixture is missing from the test bundle"
        )
        let directory = URL.temporaryDirectory.appending(path: "NeechanMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appending(path: "neechan-v1.store")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    @Test("a store written before there were two imageboards opens as 2ch's")
    func backfillsToDvach() throws {
        let url = try v1StoreCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

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
        let url = try v1StoreCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

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
        let url = try v1StoreCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

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
        let url = try v1StoreCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

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
        let url = try v1StoreCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try NeechanStore.makeContainer(at: url)
        let container = try NeechanStore.makeContainer(at: url)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Favorite>()).count == 1)
    }
}
