import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("Favorites repository")
struct FavoritesRepositoryTests {
    private func makeRepository() throws -> FavoritesRepository {
        FavoritesRepository(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    private let key = ThreadKey(board: "b", threadNum: 1)

    @Test("a thread can be added and read back")
    func addAndList() async throws {
        let repository = try makeRepository()
        #expect(try await repository.add(key, title: "Тред"))

        let items = try await repository.favorites()
        #expect(items.count == 1)
        #expect(items.first?.key == key)
        #expect(items.first?.title == "Тред")
    }

    @Test("adding the same thread twice does nothing the second time")
    func addIsIdempotent() async throws {
        let repository = try makeRepository()
        #expect(try await repository.add(key, title: "Тред"))
        #expect(try await repository.add(key, title: "Тред") == false)
        #expect(try await repository.favorites().count == 1)
    }

    @Test("toggling adds then removes")
    func toggle() async throws {
        let repository = try makeRepository()
        #expect(try await repository.toggle(key, title: "Тред"))
        #expect(try await repository.isFavorite(key))
        #expect(try await repository.toggle(key, title: "Тред") == false)
        #expect(try await repository.isFavorite(key) == false)
    }

    @Test("a renamed favourite shows the reader's own name")
    func rename() async throws {
        let repository = try makeRepository()
        try await repository.add(key, title: "Длинное название треда")
        try await repository.rename(key, to: "Моё")
        #expect(try await repository.favorites().first?.title == "Моё")

        // Clearing the name falls back to the site's.
        try await repository.rename(key, to: "   ")
        #expect(try await repository.favorites().first?.title == "Длинное название треда")
    }

    @Test("ordering follows the reader's choice", arguments: [
        FavoritesOrder.newestFirst, .oldestFirst, .title,
    ])
    func ordering(order: FavoritesOrder) async throws {
        let repository = try makeRepository()
        try await repository.add(ThreadKey(board: "b", threadNum: 1), title: "Бета")
        try await Task.sleep(for: .milliseconds(10))
        try await repository.add(ThreadKey(board: "b", threadNum: 2), title: "Альфа")

        let items = try await repository.favorites(order: order)
        switch order {
        case .newestFirst: #expect(items.map(\.key.threadNum) == [2, 1])
        case .oldestFirst: #expect(items.map(\.key.threadNum) == [1, 2])
        case .title: #expect(items.map(\.title) == ["Альфа", "Бета"])
        case .unreadFirst: break
        }
    }

    @Test("only watched threads are handed to the watcher")
    func watchedKeys() async throws {
        let repository = try makeRepository()
        try await repository.add(ThreadKey(board: "b", threadNum: 1), title: "A")
        try await repository.add(ThreadKey(board: "b", threadNum: 2), title: "B", watch: false)

        #expect(try await repository.watchedKeys().map(\.threadNum) == [1])
    }

    @Test("boards can be pinned separately from threads")
    func favoriteBoards() async throws {
        let repository = try makeRepository()
        #expect(try await repository.toggleBoard("b", name: "Бред"))
        #expect(try await repository.isFavoriteBoard("b"))
        #expect(try await repository.favoriteBoards().map(\.board) == ["b"])

        #expect(try await repository.toggleBoard("b", name: "Бред") == false)
        #expect(try await repository.favoriteBoards().isEmpty)
    }
}

/// What the badge on a favourite counts.
///
/// It used to be all-or-nothing: unless the reader had reached the very newest
/// post, the badge showed every post in the thread rather than the few that
/// had arrived since they left.
@Suite("Unread counts")
struct UnreadCountTests {
    private func makeStore() throws -> WatchedThreadStore {
        WatchedThreadStore(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    @Test("unread counts the posts that arrived since the reader left")
    func countsPostsSinceReading() async throws {
        let store = try makeStore()
        let key = ThreadKey(board: "b", threadNum: 1)

        try await store.markRead(key, upTo: 100, totalPosts: 10)
        try await store.record(key: key, postsCount: 13, maxNum: 130, isDeleted: false)

        #expect(try await store.state(for: key)?.unreadCount == 3)
    }

    @Test("being part way through a thread is not the same as having read none of it")
    func partWayThroughIsNotUnreadEverything() async throws {
        let store = try makeStore()
        let key = ThreadKey(board: "b", threadNum: 1)

        // Read to post 90 of a thread whose newest is 100: not caught up.
        try await store.markRead(key, upTo: 90, totalPosts: 10)
        try await store.record(key: key, postsCount: 12, maxNum: 100, isDeleted: false)

        #expect(try await store.state(for: key)?.unreadCount == 2)
    }

    @Test("a thread never opened counts as all unread")
    func neverOpenedIsAllUnread() async throws {
        let store = try makeStore()
        let key = ThreadKey(board: "b", threadNum: 1)

        try await store.record(key: key, postsCount: 7, maxNum: 70, isDeleted: false)

        #expect(try await store.state(for: key)?.unreadCount == 7)
    }

    @Test("reading it again clears the count")
    func readingClearsIt() async throws {
        let store = try makeStore()
        let key = ThreadKey(board: "b", threadNum: 1)
        try await store.markRead(key, upTo: 100, totalPosts: 10)
        try await store.record(key: key, postsCount: 13, maxNum: 130, isDeleted: false)

        try await store.markRead(key, upTo: 130, totalPosts: 13)

        #expect(try await store.state(for: key)?.unreadCount == 0)
    }
}

@Suite("Thread watcher")
struct ThreadWatcherTests {
    private func makeWatcher(
        _ transport: StubTransport,
        conditions: PollConditions = .unrestricted
    ) throws -> (ThreadWatcher, FavoritesRepository, WatchedThreadStore) {
        let container = try NeechanStore.makeContainer(inMemory: true)
        let favorites = FavoritesRepository(modelContainer: container)
        let states = WatchedThreadStore(modelContainer: container)
        let watcher = ThreadWatcher(
            client: DvachClient(transport: transport, domain: { .org }),
            favorites: favorites,
            states: states,
            conditions: { conditions }
        )
        return (watcher, favorites, states)
    }

    /// The recorded info response reports 42 replies, so 43 posts in total.
    private func infoData(posts: Int) -> Data {
        Data(#"{"result":1,"thread":{"num":1,"posts":\#(posts),"timestamp":1}}"#.utf8)
    }

    @Test("a first poll records the thread without inventing unread posts")
    func firstPollIsQuiet() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, states) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред")

        let results = await watcher.pollOnce()
        #expect(results.count == 1)
        #expect(results.first?.newPostCount == 0, "a thread seen for the first time has no news")
        #expect(try await states.state(for: ThreadKey(board: "b", threadNum: 1))?.lastKnownPostsCount == 11)
    }

    @Test("a second poll reports the posts that arrived between them")
    func countsNewPosts() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред")
        _ = await watcher.pollOnce()

        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 13))
        let results = await watcher.pollOnce()
        #expect(results.first?.newPostCount == 3)
        #expect(results.first?.hasNews == true)
    }

    /// Opening the Favorites tab refreshes it, and a reader coming straight
    /// back should not pay for a request per favourite to see the same numbers.
    @Test("a thread polled a moment ago is left alone")
    func skipsThreadsPolledRecently() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред")
        _ = await watcher.pollOnce()

        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 13))
        let skipped = await watcher.pollOnce(skippingPolledWithin: .seconds(60))

        #expect(skipped.isEmpty, "nothing should have been asked of the site")
    }

    @Test("a thread not polled for longer than the window is polled again")
    func pollsStaleThreads() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред")
        _ = await watcher.pollOnce()

        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 13))
        // A window so short that the poll a moment ago is already stale.
        let results = await watcher.pollOnce(skippingPolledWithin: .zero)

        #expect(results.first?.newPostCount == 3)
    }

    @Test("a thread that 404s is reported as deleted")
    func detectsDeletion() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: Data(), statusCode: 404)
        let (watcher, favorites, states) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред")

        let results = await watcher.pollOnce()
        #expect(results.first?.isDeleted == true)
        #expect(try await states.state(for: ThreadKey(board: "b", threadNum: 1))?.isDeleted == true)
    }

    @Test("being offline is remembered as a failure, not as a deletion")
    func offlineIsNotDeletion() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", failingWith: URLError(.notConnectedToInternet))
        let (watcher, favorites, states) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред")

        #expect(await watcher.pollOnce().isEmpty)
        let state = try await states.state(for: ThreadKey(board: "b", threadNum: 1))
        #expect(state?.isDeleted == false)
        #expect(state?.lastError != nil)
    }

    @Test("unwatched favourites are not polled")
    func skipsUnwatched() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 1))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред", watch: false)

        _ = await watcher.pollOnce()
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("with no favourites nothing is requested")
    func noFavorites() async throws {
        let transport = StubTransport()
        let (watcher, _, _) = try makeWatcher(transport)
        #expect(await watcher.pollOnce().isEmpty)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("reading a thread clears its unread count")
    func readingClearsUnread() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, states) = try makeWatcher(transport)
        let key = ThreadKey(board: "b", threadNum: 1)
        try await favorites.add(key, title: "Тред")
        _ = await watcher.pollOnce()

        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 20))
        _ = await watcher.pollOnce()
        #expect(try await states.state(for: key)?.unreadCount ?? 0 > 0)

        try await states.markRead(key, upTo: 1, totalPosts: 21)
        #expect(try await states.state(for: key)?.unreadCount == 0)
    }

    @Test("the favourites list carries what the watcher saw")
    func favoritesShowUnread() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(ThreadKey(board: "b", threadNum: 1), title: "Тред")
        _ = await watcher.pollOnce()

        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 15))
        _ = await watcher.pollOnce()

        let item = try await favorites.favorites().first
        #expect(item?.unreadCount ?? 0 > 0)
    }
}

@Suite("Watcher restraint")
struct ThreadWatcherRestraintTests {
    private let key = ThreadKey(board: "b", threadNum: 1)

    private func makeWatcher(
        _ transport: StubTransport,
        conditions: PollConditions = .unrestricted
    ) throws -> (ThreadWatcher, FavoritesRepository, WatchedThreadStore) {
        let container = try NeechanStore.makeContainer(inMemory: true)
        let favorites = FavoritesRepository(modelContainer: container)
        let states = WatchedThreadStore(modelContainer: container)
        let watcher = ThreadWatcher(
            client: DvachClient(transport: transport, domain: { .org }),
            favorites: favorites,
            states: states,
            conditions: { conditions }
        )
        return (watcher, favorites, states)
    }

    private func infoData(posts: Int) -> Data {
        Data(#"{"result":1,"thread":{"num":1,"posts":\#(posts),"timestamp":1}}"#.utf8)
    }

    /// The loop is restarted every time the app comes to the front, and a
    /// notification banner is enough to do it. Each restart used to be a
    /// request per favourite.
    @Test("restarting the loop does not re-ask about threads just polled")
    func restartDoesNotRepoll() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(key, title: "Тред")

        _ = await watcher.pollOnce(skippingPolledWithin: .seconds(60))
        _ = await watcher.pollOnce(skippingPolledWithin: .seconds(60))

        #expect(await transport.recordedRequests().count == 1)
    }

    @Test("a thread the site has stopped serving is never asked about again")
    func deletedThreadsAreDropped() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: Data(), statusCode: 404)
        let (watcher, favorites, states) = try makeWatcher(transport)
        try await favorites.add(key, title: "Тред")

        let first = await watcher.pollOnce()
        #expect(first.first?.isDeleted == true)
        #expect(try await states.state(for: key)?.isDeleted == true)

        _ = await watcher.pollOnce()
        #expect(await transport.recordedRequests().count == 1)
    }

    /// A closed thread can gain no posts, so asking every minute buys nothing.
    @Test("a closed thread is left alone until the long interval is up")
    func closedThreadsWait() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, states) = try makeWatcher(transport)
        try await favorites.add(key, title: "Тред")

        _ = await watcher.pollOnce()
        try await states.markRead(key, upTo: 10, totalPosts: 11, isClosed: true)

        // A full poll, which asks about everything that is due.
        _ = await watcher.pollOnce()

        #expect(await transport.recordedRequests().count == 1)
    }

    @Test("nothing is polled on cellular when the reader asked for Wi-Fi only")
    func conditionsCanForbidAPass() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(
            transport,
            conditions: PollConditions(isExpensive: true, wifiOnly: true)
        )
        try await favorites.add(key, title: "Тред")

        let results = await watcher.pollOnce()

        #expect(results.isEmpty)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("nothing is polled while the device is offline")
    func offlineSendsNothing() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(
            transport,
            conditions: PollConditions(isConnected: false)
        )
        try await favorites.add(key, title: "Тред")

        _ = await watcher.pollOnce()

        #expect(await transport.recordedRequests().isEmpty)
    }

    /// The loop asks only for what the schedule says is due, so restarting it
    /// costs nothing at all once a pass has just run.
    @Test("a due pass asks about every watched thread the first time")
    func firstDuePassAsksAboutEverything() async throws {
        let transport = StubTransport()
        for num in 1...5 {
            await transport.stub(pathSuffix: "/info/b/\(num)", data: infoData(posts: 10))
        }
        let (watcher, favorites, _) = try makeWatcher(transport)
        for num in 1...5 {
            try await favorites.add(ThreadKey(board: "b", threadNum: num), title: "Тред \(num)")
        }

        let results = await watcher.pollDue()

        #expect(results.count == 5)
        #expect(await transport.recordedRequests().count == 5)
    }

    @Test("a second due pass straight away asks about nothing")
    func secondDuePassIsQuiet() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(key, title: "Тред")

        _ = await watcher.pollDue()
        _ = await watcher.pollDue()

        #expect(await transport.recordedRequests().count == 1)
    }

    /// The background task is given a few seconds and killed if it overruns.
    @Test("a pass whose deadline has already gone sends nothing")
    func passedDeadlineSendsNothing() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        for num in 1...10 {
            await transport.stub(pathSuffix: "/info/b/\(num)", data: infoData(posts: 10))
            try await favorites.add(ThreadKey(board: "b", threadNum: num), title: "Тред")
        }

        _ = await watcher.pollDue(deadline: .now - .seconds(1))

        // The first window is started before the deadline is consulted, so the
        // pass stops after it rather than sending nothing at all.
        #expect(await transport.recordedRequests().count <= ThreadWatcher.concurrentPolls)
    }

    @Test("a thread that answered is not due again until its interval is up")
    func quietThreadsBackOff() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        let (watcher, favorites, _) = try makeWatcher(transport)
        try await favorites.add(key, title: "Тред")

        _ = await watcher.pollDue()
        let wait = await watcher.timeUntilNextPoll()

        #expect(wait > .zero)
        #expect(wait <= .seconds(60), "the first quiet poll keeps the reader's interval")
    }
}
