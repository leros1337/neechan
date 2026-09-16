import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("Thread repository")
struct ThreadRepositoryTests {
    /// Derived from the fixture rather than hard-coded, so re-recording the
    /// fixtures cannot silently break these tests.
    private let recorded: ThreadResponse
    private let key: ThreadKey
    private let threadPath: String
    private let afterPath: String

    init() throws {
        recorded = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        key = ThreadKey(board: "po", threadNum: recorded.currentThread)
        threadPath = "/po/res/\(recorded.currentThread).json"
        afterPath = "/after/po/\(recorded.currentThread)/\(recorded.maxNum)"
    }

    private func makeRepository(_ transport: StubTransport) -> ThreadRepository {
        ThreadRepository(
            key: key,
            client: DvachClient(transport: transport, domain: { .org })
        )
    }

    @Test("the first load fetches the whole thread")
    func firstLoad() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let repository = makeRepository(transport)
        let snapshot = try await repository.load()

        #expect(snapshot.posts.isEmpty == false)
        #expect(snapshot.meta.title.isEmpty == false)
        #expect(snapshot.meta.maxNum == snapshot.posts.last?.num)
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test("whether a thread has attachments is answered without walking it")
    func attachments() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let repository = makeRepository(transport)
        let snapshot = try await repository.load()

        #expect(snapshot.hasAttachments == !snapshot.allAttachments.isEmpty)
        #expect(snapshot.hasAttachments)
        #expect(ThreadSnapshot.empty(key: key).hasAttachments == false)
    }

    @Test("setting the same own posts twice rebuilds the snapshot once")
    func ownPostsAreSetOnce() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let repository = makeRepository(transport)
        let loaded = try await repository.load()
        let target = try #require(loaded.posts.first?.num)

        await repository.setOwnPostNums([target])
        let afterFirst = await repository.currentSnapshot.generation
        await repository.setOwnPostNums([target])
        let afterRepeat = await repository.currentSnapshot.generation

        #expect(afterFirst > loaded.generation, "the first call is a real change")
        #expect(afterRepeat == afterFirst, "the repeat rebuilds nothing")
        #expect(await repository.currentSnapshot.isOwn(target))
    }

    /// What the auto-refresh timer does all day. The first refresh after a load
    /// does settle the counters the server reported against the posts actually
    /// held, so it is a real change; every empty one after that must not be.
    @Test("repeated refreshes that bring nothing new keep the snapshot they had")
    func quietRefreshKeepsTheSnapshot() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))
        await transport.stub(
            pathContaining: "/after/", data: try FixtureLoader.data(.threadAfterEmpty)
        )

        let repository = makeRepository(transport)
        _ = try await repository.load()
        _ = await repository.refresh()
        let settled = await repository.currentSnapshot.generation

        _ = await repository.refresh()
        _ = await repository.refresh()

        #expect(await repository.currentSnapshot.generation == settled)
    }

    @Test("a refresh after a load asks only for the new posts")
    func refreshIsIncremental() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))
        await transport.stub(pathSuffix: afterPath,
                             data: try FixtureLoader.data(.threadAfter))

        let repository = makeRepository(transport)
        let initial = try await repository.load()
        let update = try await repository.refresh()

        guard case .appended(let snapshot, let newNums) = update else {
            Issue.record("expected new posts, got \(update)")
            return
        }
        #expect(newNums.isEmpty == false)
        #expect(snapshot.posts.count > initial.posts.count)

        let urls = await transport.requestedURLs()
        #expect(urls.last?.contains("/api/mobile/v2/after/po/\(key.threadNum)/") == true)
    }

    @Test("a refresh that brings nothing new reports no change")
    func refreshWithNothingNew() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))
        await transport.stub(pathSuffix: afterPath,
                             data: try FixtureLoader.data(.threadAfterEmpty))

        let repository = makeRepository(transport)
        _ = try await repository.load()
        let update = try await repository.refresh()

        guard case .metaChanged = update else {
            Issue.record("expected no new posts, got \(update)")
            return
        }
    }

    @Test("an incremental reply that does not line up falls back to a full load")
    func refreshFallsBackToFullLoad() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))
        // The anchor is missing from the reply, so the thread must be refetched.
        await transport.stub(
            pathSuffix: afterPath,
            data: Data(#"{"result":1,"posts":[{"num":999999999,"parent":1}]}"#.utf8)
        )

        let repository = makeRepository(transport)
        _ = try await repository.load()
        let update = try await repository.refresh()

        guard case .replaced = update else {
            Issue.record("expected a full reload, got \(update)")
            return
        }
        let urls = await transport.requestedURLs()
        #expect(urls.filter { $0.contains(threadPath) }.count == 2)
    }

    @Test("a 404 on refresh marks the thread deleted and keeps the posts")
    func deletedThreadKeepsItsPosts() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let repository = makeRepository(transport)
        let initial = try await repository.load()

        await transport.stub(pathSuffix: afterPath, data: Data(), statusCode: 404)
        await transport.stub(pathSuffix: threadPath, data: Data(), statusCode: 404)
        let update = try await repository.refresh()

        guard case .metaChanged(let snapshot) = update else {
            Issue.record("expected the thread to be marked deleted, got \(update)")
            return
        }
        #expect(snapshot.meta.isDeleted)
        #expect(snapshot.posts.count == initial.posts.count)
    }

    @Test("a network failure leaves the last good snapshot in place")
    func failureKeepsSnapshot() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let repository = makeRepository(transport)
        let initial = try await repository.load()

        await transport.stub(pathSuffix: afterPath,
                             failingWith: URLError(.notConnectedToInternet))
        let update = try await repository.refresh()

        guard case .failed(let snapshot, _) = update else {
            Issue.record("expected a failure update, got \(update)")
            return
        }
        #expect(snapshot.posts.count == initial.posts.count)
    }

    @Test("the snapshot indexes replies so backlinks are available immediately")
    func snapshotCarriesBacklinks() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let snapshot = try await makeRepository(transport).load()
        let nums = Set(snapshot.posts.map(\.num))
        var backlinkCount = 0
        for post in snapshot.posts {
            for target in snapshot.index.references(from: post.num) where nums.contains(target) {
                #expect(snapshot.index.backlinks(to: target).contains(post.num))
                backlinkCount += 1
            }
        }
        #expect(backlinkCount > 0)
    }

    @Test("own posts are carried into the snapshot")
    func ownPostsAreMarked() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let repository = makeRepository(transport)
        let first = try await repository.load()
        let target = try #require(first.posts.first?.num)

        await repository.setOwnPostNums([target])
        let snapshot = await repository.currentSnapshot
        #expect(snapshot.isOwn(target))
    }

    @Test("updates are published to observers")
    func publishesUpdates() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: threadPath, data: try FixtureLoader.data(.thread))

        let repository = makeRepository(transport)
        let updates = await repository.updates

        async let firstUpdate = updates.first { _ in true }
        _ = try await repository.load()

        let received = await firstUpdate
        guard case .replaced = try #require(received) else {
            Issue.record("expected a replace update")
            return
        }
    }
}
