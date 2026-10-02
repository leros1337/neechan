import Foundation
import NeechanAPI
import NeechanSettings
import SwiftData
import Testing
@testable import NeechanCore

/// A backup carries everything the reader built up, not only part of it.
///
/// The regression: it carried favourites, pinned boards, history, the
/// auto-hide rules and hidden threads, and nothing else. A reader restoring it
/// lost their own posts' marks, every post they had hidden, where they were in
/// each watched thread, their themes, the order of their favourites — and all
/// their settings and statistics, which the export never filled in.
@Suite("A backup carries everything")
struct BackupCompletenessTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 1)
    private let fourchanKey = ThreadKey(site: .fourchan, board: "g", threadNum: 2)
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// A store with one of everything in it.
    private func filledStore() throws -> ModelContainer {
        let container = try NeechanStore.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let favorite = Favorite(key: key, title: "Тред", createdAt: date, opThumbnailPath: "/b/thumb/1/1s.jpg")
        favorite.customTitle = "Моё"
        favorite.sortOrder = 7
        favorite.isWatched = false
        context.insert(favorite)

        context.insert(OwnPost(key: key, postNum: 5, createdAt: date))
        context.insert(OwnPost(key: fourchanKey, postNum: 6, createdAt: date))

        context.insert(HiddenPostRule(key: key, rule: .post(num: 9), createdAt: date))
        context.insert(HiddenPostRule(key: key, rule: .name("Аноним"), createdAt: date))
        context.insert(HiddenPostRule(key: fourchanKey, rule: .similar(to: "спам"), createdAt: date))

        let watched = WatchedThreadState(key: key)
        watched.lastReadPostNum = 4
        watched.lastKnownMaxNum = 20
        watched.lastKnownPostsCount = 21
        watched.unreadCount = 3
        watched.readPostsCount = 10
        watched.isClosed = true
        watched.lastPolledAt = date
        watched.scrollAnchorPostNum = 4
        watched.scrollAnchorOffset = 12.5
        context.insert(watched)

        context.insert(StoredTheme(themeID: "night", name: "Ночь", payload: Data(#"{"a":1}"#.utf8), createdAt: date))

        try context.save()
        return container
    }

    /// The source's export, through the file and back, imported into an empty
    /// store.
    private func restored() async throws -> (ModelContainer, BackupService.ImportSummary) {
        let document = try await BackupService(modelContainer: try filledStore()).export()
        let read = try BackupCodec.decode(BackupCodec.encode(document))
        let target = try NeechanStore.makeContainer(inMemory: true)
        let summary = try await BackupService(modelContainer: target).import(read)
        return (target, summary)
    }

    @Test("a favourite keeps its order, its own title and its thumbnail")
    func favoriteDetails() async throws {
        let (target, _) = try await restored()
        let favorite = try #require(try ModelContext(target).fetch(FetchDescriptor<Favorite>()).first)

        #expect(favorite.key == key)
        #expect(favorite.sortOrder == 7)
        #expect(favorite.customTitle == "Моё")
        #expect(favorite.isWatched == false)
        #expect(favorite.opThumbnailPath == "/b/thumb/1/1s.jpg")
    }

    @Test("the reader's own posts are still marked as theirs")
    func ownPosts() async throws {
        let (target, summary) = try await restored()
        let posts = try ModelContext(target).fetch(FetchDescriptor<OwnPost>())

        #expect(summary.ownPosts == 2)
        #expect(Set(posts.map { "\($0.siteRaw)/\($0.board)/\($0.postNum)" }) == ["dvach/b/5", "fourchan/g/6"])
        #expect(posts.allSatisfy { $0.createdAt == date })
    }

    @Test("every hidden post is still hidden")
    func hiddenPosts() async throws {
        let (target, summary) = try await restored()
        let rules = try ModelContext(target).fetch(FetchDescriptor<HiddenPostRule>())

        #expect(summary.hiddenPostRules == 3)
        #expect(Set(rules.compactMap(\.rule)) == [.post(num: 9), .name("Аноним"), .similar(to: "спам")])
        #expect(rules.first { $0.rule == .similar(to: "спам") }?.site == .fourchan)
    }

    @Test("a watched thread opens where it was left, with its unread count")
    func watchState() async throws {
        let (target, summary) = try await restored()
        let state = try #require(try ModelContext(target).fetch(FetchDescriptor<WatchedThreadState>()).first)

        #expect(summary.watchedThreads == 1)
        #expect(state.key == key)
        #expect(state.lastReadPostNum == 4)
        #expect(state.lastKnownMaxNum == 20)
        #expect(state.lastKnownPostsCount == 21)
        #expect(state.unreadCount == 3)
        #expect(state.readPostsCount == 10)
        #expect(state.isClosed)
        #expect(state.lastPolledAt == date)
        #expect(state.scrollAnchorPostNum == 4)
        #expect(state.scrollAnchorOffset == 12.5)
    }

    @Test("a theme comes too, so the setting that picks it has something to pick")
    func themes() async throws {
        let (target, summary) = try await restored()
        let theme = try #require(try ModelContext(target).fetch(FetchDescriptor<StoredTheme>()).first)

        #expect(summary.themes == 1)
        #expect(theme.themeID == "night")
        #expect(theme.name == "Ночь")
        #expect(theme.payload == Data(#"{"a":1}"#.utf8))
    }

    @Test("importing the same file twice adds nothing the second time")
    func idempotent() async throws {
        let document = try await BackupService(modelContainer: try filledStore()).export()
        let target = BackupService(modelContainer: try NeechanStore.makeContainer(inMemory: true))

        #expect(try await target.import(document).total > 0)
        #expect(try await target.import(document).total == 0)
    }

    @Test("the settings and statistics handed to the export are in the file")
    func preferencesAndStatistics() async throws {
        let preferences = PreferencesBackup(
            values: ["interface.textScale": .double(1.3), "board.viewModes": .strings(["b": "grid"])],
            unset: ["media.videoLoops"]
        )
        let statistics = UsageStatistics(secondsInApp: 400, postsSent: 2, threadsOpened: 3)
        let service = BackupService(modelContainer: try NeechanStore.makeContainer(inMemory: true))

        let document = try await service.export(preferences: preferences, statistics: statistics)
        let read = try BackupCodec.decode(BackupCodec.encode(document))

        #expect(read.preferencesBackup == preferences)
        #expect(read.usageStatistics == statistics)
    }

    /// A file from before any of this still reads and imports: every new part
    /// is optional, so there is nothing an older file is missing.
    @Test("a backup written before these parts existed still imports")
    func olderFileImports() async throws {
        let json = #"""
        {"version": 2, "exportedAt": "2026-01-01T00:00:00Z",
         "favorites": [{"board": "b", "threadNum": 1, "title": "Тред",
                        "createdAt": "2026-01-01T00:00:00Z", "isWatched": true, "site": "dvach"}],
         "favoriteBoards": [], "history": [], "autohideRules": [], "hiddenThreads": [],
         "settings": {}}
        """#
        let document = try BackupCodec.decode(Data(json.utf8))
        #expect(document.preferencesBackup == nil)
        #expect(document.usageStatistics == nil)

        let service = BackupService(modelContainer: try NeechanStore.makeContainer(inMemory: true))
        #expect(try await service.import(document).favorites == 1)
    }
}
