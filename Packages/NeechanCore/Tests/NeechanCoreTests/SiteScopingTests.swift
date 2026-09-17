import Foundation
import NeechanAPI
import SwiftData
import Testing
@testable import NeechanCore

/// The reader's data belongs to one imageboard at a time.
///
/// Every suite here writes the *same* board and thread number on both sites,
/// which is the case that used to collide, and then checks that each site sees
/// only its own — including when something is being deleted.
@Suite("Site scoping")
struct SiteScopingTests {
    private func container() throws -> ModelContainer {
        try NeechanStore.makeContainer(inMemory: true)
    }

    private func key(_ site: Imageboard, _ num: Int = 12345) -> ThreadKey {
        ThreadKey(site: site, board: "b", threadNum: num)
    }

    private func board(_ site: Imageboard) -> BoardRef {
        BoardRef(site: site, code: "b")
    }

    // MARK: Favourites

    @Test("favourites are listed for the imageboard being read")
    func favoritesAreScoped() async throws {
        let repository = FavoritesRepository(modelContainer: try container())
        try await repository.add(key(.dvach), title: "Двач")
        try await repository.add(key(.fourchan), title: "Fourchan")

        let dvach = try await repository.favorites(site: .dvach)
        let fourchan = try await repository.favorites(site: .fourchan)
        #expect(dvach.map(\.title) == ["Двач"])
        #expect(fourchan.map(\.title) == ["Fourchan"])
    }

    @Test("removing a favourite leaves the other imageboard's alone")
    func removingIsScoped() async throws {
        let repository = FavoritesRepository(modelContainer: try container())
        try await repository.add(key(.dvach), title: "Двач")
        try await repository.add(key(.fourchan), title: "Fourchan")

        try await repository.remove(key(.fourchan))
        #expect(try await repository.isFavorite(key(.dvach)))
        #expect(try await repository.isFavorite(key(.fourchan)) == false)
    }

    @Test("pinning the same board code on both imageboards keeps both pins")
    func favoriteBoardsAreScoped() async throws {
        let repository = FavoritesRepository(modelContainer: try container())
        #expect(try await repository.addBoard(board(.dvach), name: "Бред"))
        #expect(try await repository.addBoard(board(.fourchan), name: "Random"))

        #expect(try await repository.favoriteBoards(site: .dvach).map(\.name) == ["Бред"])
        #expect(try await repository.favoriteBoards(site: .fourchan).map(\.name) == ["Random"])
    }

    @Test("the watcher is only given the selected imageboard's threads")
    func watchedKeysAreScoped() async throws {
        let repository = FavoritesRepository(modelContainer: try container())
        try await repository.add(key(.dvach), title: "Двач")
        try await repository.add(key(.fourchan), title: "Fourchan")

        #expect(try await repository.watchedKeys(site: .dvach) == [key(.dvach)])
        #expect(try await repository.watchedKeys(site: .fourchan) == [key(.fourchan)])
    }

    /// Unread counts are looked up by a key that now carries a site, so an
    /// unscoped fetch would miss and every favourite would report nothing new.
    @Test("unread counts follow the imageboard the thread is on")
    func unreadCountsAreScoped() async throws {
        let container = try container()
        let favorites = FavoritesRepository(modelContainer: container)
        let states = WatchedThreadStore(modelContainer: container)

        try await favorites.add(key(.dvach), title: "Двач")
        try await favorites.add(key(.fourchan), title: "Fourchan")
        try await states.markRead(key(.dvach), upTo: 0, totalPosts: 1)
        try await states.record(key: key(.dvach), postsCount: 6, maxNum: 6, isDeleted: false)

        #expect(try await favorites.favorites(site: .dvach).first?.unreadCount == 5)
        #expect(try await favorites.favorites(site: .fourchan).first?.unreadCount == 0)
    }

    // MARK: History

    @Test("history is listed for the imageboard being read")
    func historyIsScoped() async throws {
        let repository = HistoryRepository(modelContainer: try container())
        try await repository.recordVisit(key(.dvach), title: "Двач")
        try await repository.recordVisit(key(.fourchan), title: "Fourchan")

        #expect(try await repository.recent(site: .dvach).map(\.title) == ["Двач"])
        #expect(try await repository.recent(site: .fourchan).map(\.title) == ["Fourchan"])
    }

    @Test("clearing history from the list clears only what the list showed")
    func clearingHistoryIsScoped() async throws {
        let repository = HistoryRepository(modelContainer: try container())
        try await repository.recordVisit(key(.dvach), title: "Двач")
        try await repository.recordVisit(key(.fourchan), title: "Fourchan")

        try await repository.clear(site: .fourchan)
        #expect(try await repository.recent(site: .dvach).count == 1)
        #expect(try await repository.recent(site: .fourchan).isEmpty)
    }

    @Test("clearing history everywhere is still possible, and says so")
    func clearingHistoryEverywhere() async throws {
        let repository = HistoryRepository(modelContainer: try container())
        try await repository.recordVisit(key(.dvach), title: "Двач")
        try await repository.recordVisit(key(.fourchan), title: "Fourchan")

        try await repository.clear(site: nil)
        #expect(try await repository.recent(site: .dvach).isEmpty)
        #expect(try await repository.recent(site: .fourchan).isEmpty)
    }

    @Test("a history search does not reach into the other imageboard")
    func historySearchIsScoped() async throws {
        let repository = HistoryRepository(modelContainer: try container())
        try await repository.recordVisit(key(.dvach), title: "Котики")
        try await repository.recordVisit(key(.fourchan), title: "Котики")

        #expect(try await repository.search("Котики", site: .dvach).count == 1)
    }

    // MARK: Hidden content

    @Test("hidden threads are listed and unhidden per imageboard")
    func hiddenThreadsAreScoped() async throws {
        let repository = HiddenContentRepository(modelContainer: try container())
        try await repository.hideThread(key(.dvach), title: "Спам")
        try await repository.hideThread(key(.fourchan), title: "Spam")

        #expect(try await repository.hiddenThreadNums(on: board(.dvach)) == [12345])
        #expect(try await repository.hiddenThreads(site: .fourchan).count == 1)

        try await repository.unhideAllThreads(site: .fourchan)
        #expect(try await repository.hiddenThreads(site: .dvach).count == 1)
        #expect(try await repository.hiddenThreads(site: .fourchan).isEmpty)
    }

    @Test("a per-thread hide belongs to one imageboard's thread")
    func localRulesAreScoped() async throws {
        let repository = HiddenContentRepository(modelContainer: try container())
        try await repository.addLocalRule(.post(num: 5), in: key(.dvach))

        #expect(try await repository.localRules(in: key(.dvach)).count == 1)
        #expect(try await repository.localRules(in: key(.fourchan)).isEmpty)
    }

    // MARK: Own posts and drafts

    @Test("a post number is only the reader's own on the site they wrote it")
    func ownPostsAreScoped() async throws {
        let repository = OwnPostsRepository(modelContainer: try container())
        try await repository.record(key(.dvach), postNum: 10)

        #expect(try await repository.isOwned(on: board(.dvach), postNum: 10))
        #expect(try await repository.isOwned(on: board(.fourchan), postNum: 10) == false)
    }

    @Test("a draft is kept per imageboard as well as per board")
    func draftsAreScoped() async throws {
        let repository = DraftRepository(modelContainer: try container())
        var draft = DraftState()
        draft.comment = "черновик"
        try await repository.save(draft, board: board(.dvach), thread: 1)

        #expect(try await repository.draft(for: board(.dvach), thread: 1).comment == "черновик")
        #expect(try await repository.draft(for: board(.fourchan), thread: 1).comment.isEmpty)
    }
}
