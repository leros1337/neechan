import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanSettings
import NeechanTestSupport
import SwiftData
import Synchronization
import Testing
@testable import NeechanCore

/// Keeping restricted boards out of everything the reader is shown.
///
/// The fixture directory already carries `/hc/` under `Взрослым`, `/b/` under
/// `Разное` and a dozen user-made boards, so these are asked of real data.
@Suite("Restricted boards are kept out of the lists")
struct RestrictedBoardsTests {
    /// A policy a test can flip between two calls, which is how the cache is
    /// proved to be unfiltered.
    private final class Gate: Sendable {
        private let open = Mutex(true)
        private var isOpen: Bool { open.withLock { $0 } }
        var provider: ContentPolicyProvider {
            { [self] in ContentPolicy(allowsMatureBoards: isOpen) }
        }
        func close() { open.withLock { $0 = false } }
    }

    private func directory(_ transport: StubTransport) async throws {
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))
    }

    private func makeRepository(_ transport: StubTransport, _ gate: Gate) -> BoardsRepository {
        BoardsRepository(
            client: DvachClient(transport: transport, site: { .init(site: .dvach, mirror: .org) }),
            site: { .init(site: .dvach, mirror: .org) },
            policy: gate.provider
        )
    }

    @Test("with the gate open the whole directory is there")
    func theGateOpenShowsEverything() async throws {
        let transport = StubTransport()
        try await directory(transport)

        let boards = try await makeRepository(transport, Gate()).boards()
        #expect(boards.contains { $0.id == "hc" })
        #expect(boards.contains { $0.id == "b" })
    }

    @Test("with the gate closed the restricted boards are gone from every listing")
    func theGateClosedHidesThem() async throws {
        let transport = StubTransport()
        try await directory(transport)
        let gate = Gate()
        gate.close()
        let repository = makeRepository(transport, gate)

        let boards = try await repository.boards()
        #expect(!boards.contains { $0.id == "hc" }, "the adult board was listed")
        #expect(!boards.contains { $0.id == "b" }, "/b/ was listed")
        #expect(boards.contains { $0.id == "a" }, "an ordinary board went missing")

        // The three other ways in all come through `boards()`.
        let categories = try await repository.categories()
        #expect(!categories.contains { $0.name == "Взрослым" })
        #expect(!categories.flatMap(\.boards).contains { $0.id == "hc" })
        #expect(try await repository.board(id: "hc") == nil)
        #expect(!(try await repository.search("")).contains { $0.id == "hc" })
        // Searching by name must not reach round the gate either.
        #expect((try await repository.search("Hardcore")).isEmpty)
    }

    @Test("every user-made board is restricted, because on 2ch they all are")
    func userBoardsAreRestricted() async throws {
        let transport = StubTransport()
        try await directory(transport)
        let gate = Gate()
        gate.close()

        let boards = try await makeRepository(transport, gate).boards()
        #expect(!boards.contains { $0.category == BoardsRepository.userBoardCategory })
    }

    /// The assertion the whole design rests on: the cache holds the site's
    /// directory unfiltered, so the gate changes the answer without a refetch.
    @Test("closing the gate re-filters the cache instead of refetching")
    func theCacheIsNotInvalidated() async throws {
        let transport = StubTransport()
        try await directory(transport)
        let gate = Gate()
        let repository = makeRepository(transport, gate)

        let before = try await repository.boards()
        gate.close()
        let after = try await repository.boards()

        #expect(before.count > after.count, "closing the gate changed nothing")
        #expect(await transport.recordedRequests().count == 1, "the directory was fetched twice")
    }

    /// A board created after this app shipped is in no table written today.
    @Test("a user board is learned from the directory, so a bare code is covered")
    func userBoardsAreLearnedFromTheDirectory() async throws {
        defer { MatureBoards.forgetLearnedBoards() }
        MatureBoards.forgetLearnedBoards()

        let transport = StubTransport()
        try await directory(transport)
        _ = try await makeRepository(transport, Gate()).boards()

        // `/ew/` is user-made in the fixture, and is in the static table too;
        // what this proves is that the directory is what teaches it, which is
        // the mechanism a genuinely new board depends on.
        #expect(MatureBoards.effectiveCodes(on: .dvach).contains("ew"))
    }
}

/// Favourites, history, saved and hidden threads on a restricted board.
///
/// Hidden, never deleted: the rows stay in the store and come back when the
/// reader opens the gate again.
@Suite("Stored threads on a restricted board")
struct RestrictedStoredThreadsTests {
    private let blocked: ContentPolicyProvider = { ContentPolicy(allowsMatureBoards: false) }

    private func container() throws -> ModelContainerBox {
        ModelContainerBox(try NeechanStore.makeContainer(inMemory: true))
    }

    private let adult = ThreadKey(site: .dvach, board: "hc", threadNum: 1)
    private let ordinary = ThreadKey(site: .dvach, board: "a", threadNum: 2)

    @Test("favourites on a restricted board are not listed, and not deleted")
    func favoritesAreHiddenNotDeleted() async throws {
        let box = try container()
        let open = FavoritesRepository(modelContainer: box.container)
        _ = try await open.add(adult, title: "Adult thread")
        _ = try await open.add(ordinary, title: "Anime thread")

        let gated = FavoritesRepository(modelContainer: box.container, policy: blocked)
        #expect(try await gated.favorites(site: .dvach).map(\.key) == [ordinary])

        // Still in the store: a different reader of the same container sees it.
        #expect(try await open.favorites(site: .dvach).count == 2)
    }

    @Test("the watcher is never given a restricted thread to poll")
    func theWatcherIsNotGivenRestrictedThreads() async throws {
        let box = try container()
        let open = FavoritesRepository(modelContainer: box.container)
        _ = try await open.add(adult, title: "Adult thread")
        _ = try await open.add(ordinary, title: "Anime thread")
        try await open.setWatched(true, for: adult)
        try await open.setWatched(true, for: ordinary)

        let gated = FavoritesRepository(modelContainer: box.container, policy: blocked)
        #expect(try await gated.watchedKeys(site: .dvach) == [ordinary])
    }

    @Test("a pinned board that is restricted is not listed")
    func pinnedBoardsAreFiltered() async throws {
        let box = try container()
        let open = FavoritesRepository(modelContainer: box.container)
        _ = try await open.addBoard(BoardRef(site: .dvach, code: "hc"), name: "Hardcore")
        _ = try await open.addBoard(BoardRef(site: .dvach, code: "a"), name: "Аниме")

        let gated = FavoritesRepository(modelContainer: box.container, policy: blocked)
        #expect(try await gated.favoriteBoards(site: .dvach).map(\.board) == ["a"])
    }

    /// The limit has to count threads the reader can open, or a run of
    /// restricted threads at the top would hide everything below it.
    @Test("history excludes restricted threads before applying its limit")
    func historyExcludesBeforeLimiting() async throws {
        let box = try container()
        let open = HistoryRepository(modelContainer: box.container)
        for num in 1...5 {
            try await open.recordVisit(
                ThreadKey(site: .dvach, board: "hc", threadNum: num), title: "Adult \(num)"
            )
        }
        try await open.recordVisit(ordinary, title: "Anime thread")

        let gated = HistoryRepository(modelContainer: box.container, policy: blocked)
        let recent = try await gated.recent(site: .dvach, limit: 3)
        #expect(recent.map(\.key) == [ordinary], "the limit was spent on restricted threads")
        #expect(try await gated.search("Adult", site: .dvach).isEmpty)
    }

    @Test("saved and hidden threads on a restricted board are not listed")
    func savedAndHiddenAreFiltered() async throws {
        let box = try container()
        let hiddenOpen = HiddenContentRepository(modelContainer: box.container)
        try await hiddenOpen.hideThread(adult, title: "Adult thread")
        try await hiddenOpen.hideThread(ordinary, title: "Anime thread")

        let gated = HiddenContentRepository(modelContainer: box.container, policy: blocked)
        #expect(try await gated.hiddenThreads(site: .dvach).map(\.key) == [ordinary])
        #expect(try await hiddenOpen.hiddenThreads(site: .dvach).count == 2)
    }
}

/// Holds a container for the length of a test, since two repositories have to
/// share one.
struct ModelContainerBox {
    let container: ModelContainer
    init(_ container: ModelContainer) { self.container = container }
}
