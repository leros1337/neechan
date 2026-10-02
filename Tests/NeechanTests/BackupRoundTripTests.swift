import Foundation
import NeechanAPI
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import Testing

/// A backup, end to end on the device: made the way the About screen makes it,
/// written to a file, read back and restored into an app with nothing in it.
///
/// The regression it guards: a backup restored the favourites and little else.
/// The settings and statistics were never written into it, and the own posts,
/// hidden posts, watch state and themes were never gathered at all.
@Suite("Backup round trip")
@MainActor
struct BackupRoundTripTests {
    private func makeServices() throws -> AppServices {
        let defaults = try #require(UserDefaults(suiteName: "backup.roundtrip.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, isAppStoreBuild: false, isRestrictedBuild: false)
        return try AppServices.inMemory(settings: settings)
    }

    @Test("everything comes back from the file")
    func everythingComesBack() async throws {
        let source = try makeServices()
        let thread = ThreadKey(site: .dvach, board: "b", threadNum: 100)
        let hiddenThread = ThreadKey(site: .dvach, board: "b", threadNum: 200)

        try await source.favorites.add(thread, title: "Тред")
        _ = try await source.favorites.addBoard(BoardRef(site: .dvach, code: "po"), name: "Политика")
        try await source.history.recordVisit(thread, title: "Тред")
        try await source.hidden.addRule(AutohideRuleValue(pattern: "спам", matchesComment: true))
        try await source.hidden.hideThread(hiddenThread, title: "Скрытый")
        try await source.hidden.addLocalRule(.post(num: 101), in: thread)
        try await source.ownPosts.record(thread, postNum: 102)
        try await source.watchedThreads.record(key: thread, postsCount: 50, maxNum: 150, isDeleted: false)
        let theme = try await source.themes.import(FixtureLoader.data(.themeDashchan))

        source.settings.themeID = theme.id
        source.settings.textScale = 1.3
        source.settings.appearance = .dark
        source.settings.setThreadsViewMode(.grid, forBoard: "b")
        for _ in 0..<3 { source.settings.recordThreadOpened() }

        // Out to a real file, the way the save panel would write it.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString)-\(BackupCodec.suggestedFileName())")
        try BackupCodec.encode(try await source.makeBackup()).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let target = try makeServices()
        let restored = try await target.restore(from: BackupCodec.decode(Data(contentsOf: file)))
        #expect(restored.restoredSettings)

        #expect(try await target.favorites.favorites(site: .dvach).map(\.key) == [thread])
        #expect(try await target.favorites.favoriteBoards(site: .dvach).map(\.board) == ["po"])
        #expect(try await target.history.recent(site: .dvach).map(\.key) == [thread])
        #expect(try await target.hidden.rules().map(\.pattern) == ["спам"])
        #expect(try await target.hidden.hiddenThreads(site: .dvach).map(\.key) == [hiddenThread])
        #expect(try await target.hidden.localRules(in: thread) == [.post(num: 101)])
        #expect(try await target.ownPosts.postNums(in: thread) == [102])
        let watched = try #require(try await target.watchedThreads.state(for: thread))
        #expect(watched.lastKnownPostsCount == 50)
        #expect(watched.lastKnownMaxNum == 150)
        #expect(try await target.themes.theme(id: theme.id).id == theme.id)

        #expect(target.settings.themeID == theme.id)
        #expect(target.settings.textScale == 1.3)
        #expect(target.settings.appearance == .dark)
        #expect(target.settings.threadsViewMode(forBoard: "b") == .grid)
        #expect(target.settings.statistics.threadsOpened == 3)
    }

    @Test("restoring the same file twice adds nothing and counts nothing twice")
    func restoringTwice() async throws {
        let source = try makeServices()
        try await source.favorites.add(ThreadKey(site: .dvach, board: "b", threadNum: 1), title: "Тред")
        for _ in 0..<4 { source.settings.recordThreadOpened() }
        let document = try await source.makeBackup()

        let target = try makeServices()
        #expect(try await target.restore(from: document).imported.total > 0)
        #expect(try await target.restore(from: document).imported.total == 0)
        #expect(target.settings.statistics.threadsOpened == 4)
    }

    @Test("a backup can move the app to the other imageboard")
    func movesTheImageboard() async throws {
        let source = try makeServices()
        source.select(.fourchan)
        let target = try makeServices()

        _ = try await target.restore(from: try await source.makeBackup())

        #expect(target.settings.imageboard == .fourchan)
        #expect(target.settings.siteSelection.site == .fourchan)
    }
}
