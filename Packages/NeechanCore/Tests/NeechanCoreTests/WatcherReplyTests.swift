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

private func afterData(_ posts: [String]) -> Data {
    Data(#"{"result":1,"unique_posters":1,"posts":[\#(posts.joined(separator: ","))]}"#.utf8)
}

private func infoData(posts: Int) -> Data {
    Data(#"{"result":1,"thread":{"num":1,"posts":\#(posts),"timestamp":1}}"#.utf8)
}

/// The watcher reads the new posts of a thread the reader has written in, so
/// "Replies to me" can tell an answer from any other post.
@Suite("Watcher replies")
struct WatcherReplyTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 1)

    private struct Fixture {
        let watcher: ThreadWatcher
        let states: WatchedThreadStore
        let ownPosts: OwnPostsRepository
        let transport: StubTransport
    }

    /// A watched thread already polled once at 10 replies, so the next poll
    /// that sees more has news.
    private func makeFixture(ownPostNums: [Int]) async throws -> Fixture {
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
        await transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 10))
        _ = await watcher.pollOnce()
        return Fixture(watcher: watcher, states: states, ownPosts: ownPosts, transport: transport)
    }

    private func afterPaths(_ transport: StubTransport) async -> [String] {
        await transport.recordedRequests()
            .compactMap { $0.url?.path() }
            .filter { $0.contains("/after/") }
    }

    @Test("a new post quoting the reader's post is reported as a reply")
    func reportsReply() async throws {
        let fixture = try await makeFixture(ownPostNums: [5])
        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 12))
        await fixture.transport.stub(
            pathContaining: "/after/b/1/",
            data: afterData([postJSON(5), postJSON(6, replyingTo: [5]), postJSON(7, replyingTo: [6])])
        )

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 2)
        #expect(results.first?.replies == [6], "only the post quoting the reader's own counts")
    }

    @Test("a thread the reader has not written in costs no extra request")
    func noOwnPostsNoFetch() async throws {
        let fixture = try await makeFixture(ownPostNums: [])
        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 12))

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 2)
        #expect(results.first?.replies == [])
        #expect(await afterPaths(fixture.transport).isEmpty)
    }

    @Test("a quiet poll asks for no posts")
    func noNewsNoFetch() async throws {
        let fixture = try await makeFixture(ownPostNums: [5])

        _ = await fixture.watcher.pollOnce()

        #expect(await afterPaths(fixture.transport).isEmpty)
    }

    /// Anything up to where the reader stopped reading has been seen, so an
    /// answer there is not news.
    @Test("the check starts after what the reader has already read")
    func anchorsAtLastRead() async throws {
        let fixture = try await makeFixture(ownPostNums: [5])
        try await fixture.states.markRead(key, upTo: 8, totalPosts: 11)
        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 12))
        await fixture.transport.stub(
            pathContaining: "/after/b/1/",
            data: afterData([postJSON(8), postJSON(9, replyingTo: [5])])
        )

        let results = await fixture.watcher.pollOnce()

        #expect(await afterPaths(fixture.transport).last?.hasSuffix("/after/b/1/8") == true)
        #expect(results.first?.replies == [9])
    }

    @Test("a reply is reported once, not again on the next poll")
    func reportsReplyOnce() async throws {
        let fixture = try await makeFixture(ownPostNums: [5])
        await fixture.transport.stub(
            pathContaining: "/after/b/1/",
            data: afterData([postJSON(5), postJSON(6, replyingTo: [5]), postJSON(7)])
        )
        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 12))
        _ = await fixture.watcher.pollOnce()

        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 13))
        let results = await fixture.watcher.pollOnce()

        #expect(await afterPaths(fixture.transport).last?.hasSuffix("/after/b/1/7") == true)
        #expect(results.first?.replies == [])
    }

    @Test("the reader answering their own post is not a reply")
    func ignoresOwnFollowUp() async throws {
        let fixture = try await makeFixture(ownPostNums: [5, 6])
        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 12))
        await fixture.transport.stub(
            pathContaining: "/after/b/1/",
            data: afterData([postJSON(6, replyingTo: [5]), postJSON(7)])
        )

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.replies == [])
    }

    /// The site will not serve "posts after N" once N is gone, and the
    /// reader's own post is exactly the kind a moderator deletes.
    @Test("a deleted anchor falls back to the opening post")
    func fallsBackWhenAnchorIsGone() async throws {
        let fixture = try await makeFixture(ownPostNums: [5])
        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 12))
        await fixture.transport.stub(
            pathSuffix: "/after/b/1/1",
            data: afterData([postJSON(1), postJSON(6, replyingTo: [5]), postJSON(7)])
        )
        await fixture.transport.stub(
            pathSuffix: "/after/b/1/5",
            data: try FixtureLoader.data(.errorNoPost)
        )

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.replies == [6])
    }

    @Test("a failed check still reports the new posts")
    func failedCheckKeepsCount() async throws {
        let fixture = try await makeFixture(ownPostNums: [5])
        await fixture.transport.stub(pathSuffix: "/info/b/1", data: infoData(posts: 12))
        await fixture.transport.stub(
            pathContaining: "/after/b/1/",
            data: Data(),
            statusCode: 500
        )

        let results = await fixture.watcher.pollOnce()

        #expect(results.first?.newPostCount == 2)
        #expect(results.first?.replies == [])
    }
}
