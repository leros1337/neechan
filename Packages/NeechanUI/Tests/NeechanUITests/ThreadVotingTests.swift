import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// Likes and dislikes, from the thread.
@Suite("Voting in a thread")
@MainActor
struct ThreadVotingTests {
    private let recorded: ThreadResponse
    private let key: ThreadKey

    init() throws {
        recorded = try FixtureLoader.decode(ThreadResponse.self, from: .thread)
        key = ThreadKey(site: .dvach, board: "po", threadNum: recorded.currentThread)
    }

    /// The recorded thread, on a board with likes turned on, with counts on
    /// every post: 10 likes and 2 dislikes.
    private func threadWithLikes(enabled: Bool = true) throws -> Data {
        var json = try #require(
            try JSONSerialization.jsonObject(with: FixtureLoader.data(.thread)) as? [String: Any]
        )
        var board = try #require(json["board"] as? [String: Any])
        board["enable_likes"] = enabled
        json["board"] = board
        var threads = try #require(json["threads"] as? [[String: Any]])
        let posts = try #require(threads[0]["posts"] as? [[String: Any]])
        threads[0]["posts"] = posts.map { post in
            var post = post
            post["likes"] = 10
            post["dislikes"] = 2
            return post
        }
        json["threads"] = threads
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func loadedModel(
        likes: Bool = true,
        isAppStoreBuild: Bool = false,
        vote reply: Data? = Data(#"{"result":1,"error":null}"#.utf8)
    ) async throws -> (ThreadViewModel, StubTransport) {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/po/res/\(recorded.currentThread).json",
            data: try threadWithLikes(enabled: likes)
        )
        if let reply {
            await transport.stub(pathSuffix: "/api/like", data: reply)
            await transport.stub(pathSuffix: "/api/dislike", data: reply)
        }
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "ThreadVotingTests.\(UUID().uuidString)")!,
            isAppStoreBuild: isAppStoreBuild
        )
        settings.imageboard = .dvach
        let services = try AppServices.inMemory(settings: settings, transport: transport)
        let model = ThreadViewModel(key: key, services: services)
        await model.load()
        return (model, transport)
    }

    private func voteRequests(_ transport: StubTransport) async -> [URLRequest] {
        await transport.recordedRequests().filter { $0.url?.path().hasPrefix("/api/") == true }
    }

    @Test("a like counts at once and is sent to the site")
    func likeCountsAtOnce() async throws {
        let (model, transport) = try await loadedModel()
        let post = try #require(model.snapshot.posts.first)

        #expect(model.canVote)
        await model.vote(post.num, like: true)

        #expect(model.likes(of: post) == 11)
        #expect(model.dislikes(of: post) == 2)
        let request = try #require(await voteRequests(transport).last)
        #expect(request.url?.path() == "/api/like")
        #expect(request.url?.query() == "board=po&num=\(post.num)")
    }

    @Test("a dislike counts against the post")
    func dislikeCounts() async throws {
        let (model, _) = try await loadedModel()
        let post = try #require(model.snapshot.posts.first)

        await model.vote(post.num, like: false)

        #expect(model.likes(of: post) == 10)
        #expect(model.dislikes(of: post) == 3)
        #expect(model.vote(on: post.num) == .dislike)
    }

    /// The site's own sentence is what reaches the reader, the way a refused
    /// report's does.
    @Test("a refused vote takes the count back and says why")
    func refusedVoteReverts() async throws {
        let (model, _) = try await loadedModel(vote: try FixtureLoader.data(.likeForbidden))
        let post = try #require(model.snapshot.posts.first)

        await model.vote(post.num, like: true)

        #expect(model.likes(of: post) == 10)
        #expect(model.vote(on: post.num) == nil)
        #expect(model.notice == "Постинг запрещён.")
    }

    /// The site counts one vote per reader, and a second is refused anyway.
    @Test("a post already voted on is not sent again")
    func oneVotePerPost() async throws {
        let (model, transport) = try await loadedModel()
        let post = try #require(model.snapshot.posts.first)

        await model.vote(post.num, like: true)
        await model.vote(post.num, like: false)

        #expect(model.likes(of: post) == 11)
        #expect(model.dislikes(of: post) == 2)
        #expect(await voteRequests(transport).count == 1)
    }

    /// A vote is writing to the site, as a post is, and follows the same
    /// switch. The counts are still worth reading.
    @Test("where posting is off the counts show and nothing is sent")
    func noVotingWithoutPosting() async throws {
        let (model, transport) = try await loadedModel(isAppStoreBuild: true)
        let post = try #require(model.snapshot.posts.first)

        #expect(model.showsVotes)
        #expect(model.canVote == false)
        await model.vote(post.num, like: true)

        #expect(model.likes(of: post) == 10)
        #expect(await voteRequests(transport).isEmpty)
    }

    @Test("a board without likes shows no counts and takes no votes")
    func boardWithoutLikes() async throws {
        let (model, transport) = try await loadedModel(likes: false)
        let post = try #require(model.snapshot.posts.first)

        #expect(model.showsVotes == false)
        #expect(model.canVote == false)
        await model.vote(post.num, like: true)
        #expect(await voteRequests(transport).isEmpty)
    }
}
