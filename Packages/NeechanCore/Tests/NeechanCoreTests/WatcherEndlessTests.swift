import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanCore

/// A post as `/after` serves it, quoting `targets` inside thread 1.
private func postJSON(_ num: Int, replyingTo targets: [Int] = []) -> String {
    let links = targets.map {
        #"<a class=\"post-reply-link\" data-thread=\"1\" data-num=\"\#($0)\">&gt;&gt;\#($0)</a>"#
    }.joined(separator: "<br>")
    return #"{"num":\#(num),"parent":1,"board":"b","comment":"\#(links)"}"#
}

private func afterData(_ nums: [Int]) -> Data {
    afterData(nums.map { postJSON($0) })
}

private func afterData(_ posts: [String]) -> Data {
    Data(#"{"result":1,"unique_posters":1,"posts":[\#(posts.joined(separator: ","))]}"#.utf8)
}

/// The count an endless thread reports once it is full, and keeps reporting.
private func infoData(posts: Int = 999) -> Data {
    Data(#"{"result":1,"thread":{"num":1,"posts":\#(posts),"timestamp":1}}"#.utf8)
}

/// The opening post as `/post` serves it, which is where "endless" is said.
private func openingPostData(endless: Bool) -> Data {
    Data(
        #"{"result":1,"post":{"num":1,"parent":0,"board":"b","comment":"","endless":\#(endless ? 1 : 0)}}"#
            .utf8
    )
}

/// An endless thread drops its oldest post for every new one, so once it is
/// full its count never moves. The watcher has to go by post numbers instead,
/// or it never reports anything there: no new posts, no replies, no badge.
@Suite("Watcher on endless threads")
struct WatcherEndlessTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 1)

    private struct Fixture {
        let watcher: ThreadWatcher
        let states: WatchedThreadStore
        let transport: StubTransport
    }

    /// A watched thread already polled once at its full count.
    private func makeFixture(ownPostNums: [Int] = []) async throws -> Fixture {
        let transport = StubTransport()
        let container = try NeechanStore.makeContainer(inMemory: true)
        let favorites = FavoritesRepository(modelContainer: container)
        let states = WatchedThreadStore(modelContainer: container)
        let ownPosts = OwnPostsRepository(modelContainer: container)
        let watcher = ThreadWatcher(
            client: DvachClient(transport: transport, site: { .init(site: .dvach, mirror: .org) }),
            site: { .init(site: .dvach, mirror: .org) },
            favorites: favorites,
            states: states,
            ownPosts: ownPosts
        )
        try await favorites.add(key, title: "Тред")
        for num in ownPostNums {
            try await ownPosts.record(key, postNum: num)
        }
        await transport.stub(pathSuffix: "/info/b/1", data: infoData())
        _ = await watcher.pollOnce()
        return Fixture(watcher: watcher, states: states, transport: transport)
    }

    private func paths(_ transport: StubTransport, containing fragment: String) async -> [String] {
        await transport.recordedRequests()
            .compactMap { $0.url?.path() }
            .filter { $0.contains(fragment) }
    }

    @Test("a full endless thread still reports the posts that arrived")
    func reportsNewPostsPastTheCount() async throws {
        let fixture = try await makeFixture()
        try await fixture.states.markRead(key, upTo: 50, totalPosts: 1000, isEndless: true)
        await fixture.transport.stub(pathSuffix: "/post/b/1", data: openingPostData(endless: true))
        await fixture.transport.stub(pathSuffix: "/after/b/1/50", data: afterData([50, 51, 52, 53]))

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 3)
        #expect(try await fixture.states.state(for: key)?.unreadCount == 3)
    }

    @Test("an answer to the reader in an endless thread is reported")
    func reportsReply() async throws {
        let fixture = try await makeFixture(ownPostNums: [50])
        try await fixture.states.markRead(key, upTo: 50, totalPosts: 1000, isEndless: true)
        await fixture.transport.stub(pathSuffix: "/post/b/1", data: openingPostData(endless: true))
        await fixture.transport.stub(
            pathSuffix: "/after/b/1/50",
            data: afterData([postJSON(50), postJSON(51, replyingTo: [50]), postJSON(52)])
        )

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 2)
        #expect(results.first?.replies == [51])
    }

    /// Once the watcher knows, the count is not worth asking for: it says
    /// nothing, and the posts themselves say everything.
    @Test("the opening post is asked about once, and the count not at all after")
    func asksOnceThenGoesByNumber() async throws {
        let fixture = try await makeFixture()
        try await fixture.states.markRead(key, upTo: 50, totalPosts: 1000, isEndless: true)
        await fixture.transport.stub(pathSuffix: "/post/b/1", data: openingPostData(endless: true))
        await fixture.transport.stub(pathSuffix: "/after/b/1/50", data: afterData([50, 51, 52, 53]))
        _ = await fixture.watcher.pollOnce()
        let infoBefore = await paths(fixture.transport, containing: "/info/").count

        await fixture.transport.stub(pathSuffix: "/after/b/1/53", data: afterData([53, 54]))
        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 1)
        #expect(await paths(fixture.transport, containing: "/post/").count == 1)
        #expect(await paths(fixture.transport, containing: "/info/").count == infoBefore)
        #expect(await paths(fixture.transport, containing: "/after/").last?.hasSuffix("/after/b/1/53") == true)
    }

    @Test("a thread that is not endless keeps the count-only poll")
    func ordinaryThreadKeepsCounting() async throws {
        let fixture = try await makeFixture()
        await fixture.transport.stub(pathSuffix: "/post/b/1", data: openingPostData(endless: false))
        _ = await fixture.watcher.pollOnce()

        _ = await fixture.watcher.pollOnce()

        #expect(await paths(fixture.transport, containing: "/post/").count == 1)
        #expect(await paths(fixture.transport, containing: "/after/").isEmpty)
        #expect(await paths(fixture.transport, containing: "/info/").count == 3)
    }

    @Test("a thread the reader has been in needs no asking")
    func notedThreadSkipsTheProbe() async throws {
        let fixture = try await makeFixture()
        try await fixture.states.markRead(key, upTo: 50, totalPosts: 1000, isEndless: true)
        await fixture.watcher.noteThread(key, isEndless: true)
        await fixture.transport.stub(pathSuffix: "/after/b/1/50", data: afterData([50, 51]))

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 1)
        #expect(await paths(fixture.transport, containing: "/post/").isEmpty)
        #expect(await paths(fixture.transport, containing: "/info/").count == 1, "only the fixture's")
    }

    /// The newest post the watcher saw may be one a moderator removed, and the
    /// site will not serve "posts after" a post it no longer has.
    @Test("a missing anchor falls back to the opening post")
    func missingAnchorFallsBack() async throws {
        let fixture = try await makeFixture()
        try await fixture.states.markRead(key, upTo: 50, totalPosts: 1000, isEndless: true)
        await fixture.watcher.noteThread(key, isEndless: true)
        await fixture.transport.stub(
            pathSuffix: "/after/b/1/50", data: try FixtureLoader.data(.errorNoPost)
        )
        await fixture.transport.stub(pathSuffix: "/after/b/1/1", data: afterData([1, 48, 49, 51, 52]))

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 2)
        #expect(results.first?.isDeleted == false)
    }

    @Test("an endless thread that is gone is reported deleted")
    func deletedThread() async throws {
        let fixture = try await makeFixture()
        try await fixture.states.markRead(key, upTo: 50, totalPosts: 1000, isEndless: true)
        await fixture.watcher.noteThread(key, isEndless: true)
        await fixture.transport.stub(
            pathSuffix: "/after/b/1/50", data: try FixtureLoader.data(.errorNoPost)
        )
        await fixture.transport.stub(pathSuffix: "/after/b/1/1", data: Data(), statusCode: 404)

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.isDeleted == true)
        #expect(try await fixture.states.state(for: key)?.isDeleted == true)
    }

    /// A thread favourited from the board list and never opened has no post
    /// to count from, so everything in it is old news the first time.
    @Test("the first look at an endless thread invents no news")
    func firstLookIsQuiet() async throws {
        let fixture = try await makeFixture()
        await fixture.watcher.noteThread(key, isEndless: true)
        await fixture.transport.stub(pathSuffix: "/after/b/1/1", data: afterData([1, 2, 3, 4]))

        let first = await fixture.watcher.pollOnce()
        #expect(first.first?.newPostCount == 0)

        await fixture.transport.stub(pathSuffix: "/after/b/1/4", data: afterData([4, 5]))
        let second = await fixture.watcher.pollOnce()
        #expect(second.first?.newPostCount == 1)
    }
}

/// What the badge on an endless thread counts: the posts that arrived, since
/// the count it would otherwise subtract has stopped moving.
@Suite("Unread counts on endless threads")
struct EndlessUnreadCountTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 1)

    private func makeStore() throws -> WatchedThreadStore {
        WatchedThreadStore(modelContainer: try NeechanStore.makeContainer(inMemory: true))
    }

    @Test("arrivals add up until the reader comes back")
    func arrivalsAddUp() async throws {
        let store = try makeStore()
        try await store.markRead(key, upTo: 100, totalPosts: 1000, isEndless: true)

        try await store.recordArrivals(key: key, newPosts: 3, maxNum: 103)
        try await store.recordArrivals(key: key, newPosts: 2, maxNum: 105)
        #expect(try await store.state(for: key)?.unreadCount == 5)

        try await store.markRead(key, upTo: 105, totalPosts: 1000, isEndless: true)
        #expect(try await store.state(for: key)?.unreadCount == 0)
    }

    @Test("unread never exceeds what the thread can hold")
    func capped() async throws {
        let store = try makeStore()
        try await store.markRead(key, upTo: 100, totalPosts: 1000, isEndless: true)

        try await store.recordArrivals(key: key, newPosts: 900, maxNum: 1000)
        try await store.recordArrivals(key: key, newPosts: 900, maxNum: 1900)

        #expect(try await store.state(for: key)?.unreadCount == 1000)
    }

    @Test("the newest post seen moves forward and never back")
    func maxNumOnlyGrows() async throws {
        let store = try makeStore()
        try await store.recordArrivals(key: key, newPosts: 1, maxNum: 200)
        try await store.recordArrivals(key: key, newPosts: 0, maxNum: 150)

        #expect(try await store.state(for: key)?.lastKnownMaxNum == 200)
    }
}
