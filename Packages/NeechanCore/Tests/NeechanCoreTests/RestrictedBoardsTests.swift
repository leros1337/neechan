import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanSettings
import NeechanTestSupport
import SwiftData
import Synchronization
import Testing
@testable import NeechanCore

/// What the board directory lists, and what the age gate does instead.
///
/// The fixture directory already carries `/hc/` under `Взрослым`, `/b/` under
/// `Разное` and a dozen user-made boards, so these are asked of real data.
///
/// Two separate questions live here and they are deliberately not the same
/// one. The directory is narrowed by the *build*: every build but the App
/// Store one lists the whole site. The age gate decides what may be *opened*,
/// and is asked at the door rather than by hiding the door.
@Suite("What the board directory lists")
struct RestrictedBoardsTests {
    /// A policy a test can change between two calls, which is how the cache is
    /// proved to be unfiltered.
    private final class Policy: Sendable {
        private let current: Mutex<ContentPolicy>
        init(_ initial: ContentPolicy = .unrestricted) { current = Mutex(initial) }
        var provider: ContentPolicyProvider { { [self] in current.withLock { $0 } } }
        func set(_ policy: ContentPolicy) { current.withLock { $0 = policy } }
    }

    /// The App Store build: anime, manga and comics, whatever the reader's age
    /// gate says.
    private static let appStore = ContentPolicy(
        allowsMatureBoards: false, listsEveryBoard: false
    )

    private func directory(_ transport: StubTransport) async throws {
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))
    }

    private func makeRepository(_ transport: StubTransport, _ policy: Policy) -> BoardsRepository {
        BoardsRepository(
            client: DvachClient(transport: transport, site: { .init(site: .dvach, mirror: .org) }),
            site: { .init(site: .dvach, mirror: .org) },
            policy: policy.provider
        )
    }

    @Test("an ordinary build lists the whole directory")
    func theOrdinaryBuildShowsEverything() async throws {
        let transport = StubTransport()
        try await directory(transport)

        let boards = try await makeRepository(transport, Policy()).boards()
        #expect(boards.contains { $0.id == "hc" })
        #expect(boards.contains { $0.id == "b" })
    }

    /// The change of heart in this design: closing the age gate used to empty
    /// half the directory, which left a reader hunting for a board that had
    /// silently gone. Now nothing moves and the refusal happens at the door,
    /// where it can say why and offer the way through.
    @Test("closing the age gate does not change what is listed")
    func theAgeGateDoesNotFilterTheDirectory() async throws {
        let transport = StubTransport()
        try await directory(transport)
        let policy = Policy(ContentPolicy(allowsMatureBoards: false))

        let boards = try await makeRepository(transport, policy).boards()
        #expect(boards.contains { $0.id == "hc" }, "the age gate hid an adult board")
        #expect(boards.contains { $0.id == "b" }, "the age gate hid /b/")
        #expect(boards.contains { $0.category == BoardsRepository.userBoardCategory })
    }

    @Test("what the age gate does instead is refuse to open them")
    func theAgeGateRefusesAtTheDoor() {
        let closed = ContentPolicy(allowsMatureBoards: false)
        #expect(!closed.allowsOpening(code: "hc", on: .dvach))
        #expect(!closed.allowsOpening(code: "b", on: .dvach))
        #expect(closed.allowsOpening(code: "a", on: .dvach))

        let open = ContentPolicy(allowsMatureBoards: true)
        #expect(open.allowsOpening(code: "hc", on: .dvach))
    }

    @Test("the App Store build lists anime, manga and comics and nothing else")
    func theAppStoreDirectoryIsNarrow() async throws {
        let transport = StubTransport()
        try await directory(transport)
        let repository = makeRepository(transport, Policy(Self.appStore))

        let boards = try await repository.boards()
        #expect(boards.contains { $0.id == "a" }, "anime went missing")
        #expect(!boards.contains { $0.id == "hc" }, "an adult board was listed")
        #expect(!boards.contains { $0.id == "b" }, "/b/ was listed")
        #expect(!boards.contains { $0.id == "vg" }, "an off-topic board was listed")

        // The three other ways in all come through `boards()`.
        let categories = try await repository.categories()
        #expect(!categories.contains { $0.name == "Взрослым" })
        #expect(!categories.flatMap(\.boards).contains { $0.id == "hc" })
        #expect(try await repository.board(id: "hc") == nil)
        #expect(!(try await repository.search("")).contains { $0.id == "hc" })
        // Searching by name must not reach round it either.
        #expect((try await repository.search("Hardcore")).isEmpty)
    }

    /// Turning the age gate on is what lets a reader reach the rest of the
    /// site by typing a code. It still does not widen the list.
    @Test("the App Store directory stays narrow even with the age gate open")
    func theAppStoreDirectoryIgnoresTheAgeGate() async throws {
        let transport = StubTransport()
        try await directory(transport)
        let policy = Policy(
            ContentPolicy(allowsMatureBoards: true, listsEveryBoard: false)
        )

        let boards = try await makeRepository(transport, policy).boards()
        #expect(!boards.contains { $0.id == "hc" }, "the age gate widened the directory")
        #expect(Self.appStore.allowsOpening(code: "a", on: .dvach))
        #expect(
            ContentPolicy(allowsMatureBoards: true, listsEveryBoard: false)
                .allowsOpening(code: "hc", on: .dvach),
            "the age gate did not unlock a board by code"
        )
    }

    /// The assertion the whole design rests on: the cache holds the site's
    /// directory unfiltered, so the policy changes the answer without a refetch.
    @Test("narrowing the directory re-filters the cache instead of refetching")
    func theCacheIsNotInvalidated() async throws {
        let transport = StubTransport()
        try await directory(transport)
        let policy = Policy()
        let repository = makeRepository(transport, policy)

        let before = try await repository.boards()
        policy.set(Self.appStore)
        let after = try await repository.boards()

        #expect(before.count > after.count, "narrowing the directory changed nothing")
        #expect(await transport.recordedRequests().count == 1, "the directory was fetched twice")
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
