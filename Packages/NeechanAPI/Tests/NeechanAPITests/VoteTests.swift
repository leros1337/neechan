import Foundation
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

/// Likes and dislikes, on the 2ch boards that have them.
@Suite("Voting")
struct VoteTests {
    private let dvach = SiteSelection(site: .dvach, mirror: .org)

    private func makeClient(_ transport: StubTransport, site: Imageboard = .dvach) -> DvachClient {
        DvachClient(transport: transport, site: { .init(site: site, mirror: .org) }, retryPolicy: .none)
    }

    private func stubbed(_ path: String, _ json: String) async -> StubTransport {
        let transport = StubTransport()
        await transport.stub(pathSuffix: path, data: Data(json.utf8))
        return transport
    }

    // MARK: The request

    @Test("a dislike is a GET to /api/dislike naming the board and the post")
    func dislikeRequest() throws {
        let request = try #require(ImageboardEndpoint.dislike(board: "news", num: 5).request(for: dvach))

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://2ch.org/api/dislike?board=news&num=5")
    }

    // MARK: The reply

    @Test("a like the site accepts returns without complaint")
    func likeAccepted() async throws {
        let transport = await stubbed("/api/like", #"{"result":1,"error":null}"#)

        try await LikeService(client: makeClient(transport)).like(board: "news", num: 5)

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.query() == "board=news&num=5")
    }

    /// The reply makaba gave for years, still what its own pages expect. A
    /// reader's vote must not be called a failure for being answered the old
    /// way, which is what decoding it as a report's reply did.
    @Test("the older reply, capitalised and without a result, is a success too")
    func olderReplyAccepted() async throws {
        let transport = await stubbed("/api/dislike", #"{"Error":null,"Status":"OK"}"#)

        try await LikeService(client: makeClient(transport)).dislike(board: "news", num: 5)
    }

    @Test("a refused vote is raised in the site's words")
    func refusedVote() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/api/like", data: try FixtureLoader.data(.likeForbidden))

        do {
            try await LikeService(client: makeClient(transport)).like(board: "news", num: 5)
            Issue.record("the refusal was not raised")
        } catch {
            #expect(error.code == .noAccess)
            #expect(error.serverMessage == "Постинг запрещён.")
        }
    }

    @Test("a refusal in the older reply is raised as well")
    func olderRefusal() async throws {
        let transport = await stubbed("/api/like", #"{"Error":-4,"Reason":"Постинг запрещён."}"#)

        do {
            try await LikeService(client: makeClient(transport)).like(board: "news", num: 5)
            Issue.record("the refusal was not raised")
        } catch {
            #expect(error.code == .noAccess)
            #expect(error.serverMessage == "Постинг запрещён.")
        }
    }

    @Test("4chan has no voting to ask for")
    func fourchanUnsupported() async throws {
        let transport = StubTransport()

        do {
            try await LikeService(client: makeClient(transport, site: .fourchan)).like(board: "g", num: 1)
            Issue.record("a vote was sent to 4chan")
        } catch {
            guard case .unsupported = error else {
                Issue.record("expected .unsupported, got \(error)")
                return
            }
        }
        #expect(await transport.lastRequest() == nil)
    }
}
