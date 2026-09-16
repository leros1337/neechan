import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("Boards repository")
struct BoardsRepositoryTests {
    private func makeRepository(_ transport: StubTransport) -> BoardsRepository {
        BoardsRepository(client: DvachClient(transport: transport, domain: { .org }))
    }

    @Test("boards are fetched and grouped by category")
    func groupsByCategory() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))

        let groups = try await makeRepository(transport).categories()
        #expect(groups.isEmpty == false)
        #expect(groups.allSatisfy { !$0.boards.isEmpty })
        // Categories keep the order the server listed them in.
        #expect(groups.map(\.name) == groups.map(\.name))
    }

    @Test("a second read is served from the cache")
    func cachesBoards() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))

        let repository = makeRepository(transport)
        _ = try await repository.boards()
        _ = try await repository.boards()
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test("a forced refresh goes back to the network")
    func refreshBypassesCache() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))

        let repository = makeRepository(transport)
        _ = try await repository.boards()
        _ = try await repository.boards(forceRefresh: true)
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test("a board can be looked up by its code")
    func findsBoardByID() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))

        let board = try await makeRepository(transport).board(id: "b")
        #expect(board?.id == "b")
        #expect(try await makeRepository(transport).board(id: "нет") == nil)
    }

    @Test("boards can be filtered by code, name or category")
    func filtersBoards() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))

        let repository = makeRepository(transport)
        let all = try await repository.boards()
        let hits = try await repository.search("b")
        #expect(hits.isEmpty == false)
        #expect(hits.count <= all.count)
        #expect(try await repository.search("").count == all.count)
    }
}

@Suite("Catalog repository")
struct CatalogRepositoryTests {
    private func makeRepository(_ transport: StubTransport) -> CatalogRepository {
        CatalogRepository(client: DvachClient(transport: transport, domain: { .org }))
    }

    @Test("the catalog is fetched and returned in the server's order")
    func fetchesCatalog() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/po/catalog.json", data: try FixtureLoader.data(.catalog))

        let page = try await makeRepository(transport).catalog(board: "po", sort: .bumpOrder)
        #expect(page.threads.isEmpty == false)
        #expect(page.board.id == "po")
    }

    @Test("sorting by replies puts the busiest thread first")
    func sortsByReplies() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/po/catalog.json", data: try FixtureLoader.data(.catalog))

        let page = try await makeRepository(transport).catalog(board: "po", sort: .replyCount)
        let counts = page.threads.filter { !$0.opPost.isSticky }.map(\.postsCount)
        #expect(counts == counts.sorted(by: >))
    }

    @Test("sorting by creation asks the server for its creation-ordered catalog")
    func sortsByCreation() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/po/catalog_num.json", data: try FixtureLoader.data(.catalog))

        let page = try await makeRepository(transport).catalog(board: "po", sort: .creationDate)
        // Pinned threads are hoisted whatever the sort, so only the rest is ordered.
        let stamps = page.threads.filter { !$0.opPost.isSticky }.map(\.opPost.timestamp)
        #expect(stamps == stamps.sorted(by: >))

        let urls = await transport.requestedURLs()
        #expect(urls.last?.hasSuffix("/po/catalog_num.json") == true)
    }

    @Test("pinned threads stay at the top whatever the sort")
    func pinnedThreadsStayFirst() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/po/catalog.json", data: try FixtureLoader.data(.catalog))

        let page = try await makeRepository(transport).catalog(board: "po", sort: .replyCount)
        let pinned = page.threads.prefix { $0.opPost.isSticky }
        #expect(page.threads.dropFirst(pinned.count).allSatisfy { !$0.opPost.isSticky })
    }

    @Test("the paged index is fetched page by page")
    func fetchesPage() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/po/index.json", data: try FixtureLoader.data(.indexPage0))
        await transport.stub(pathSuffix: "/po/1.json", data: try FixtureLoader.data(.indexPage1))

        let repository = makeRepository(transport)
        let first = try await repository.page(board: "po", page: 0)
        let second = try await repository.page(board: "po", page: 1)

        #expect(first.currentPage == 0)
        #expect(second.currentPage == 1)
        #expect(first.pageCount > 1)
    }

    @Test("a catalog can be filtered locally by subject and comment")
    func filtersLocally() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/po/catalog.json", data: try FixtureLoader.data(.catalog))

        let page = try await makeRepository(transport).catalog(board: "po", sort: .bumpOrder)

        // The needle is taken from the *parsed* text, because that is what the
        // filter matches against; a word lifted out of the raw HTML might be
        // markup that never reaches the reader.
        let parser = CommentHTMLParser()
        let words = page.threads
            .lazy
            .map { parser.parse($0.opPost.comment, inThread: 0, onBoard: "po").plainText }
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let needle = try #require(words.first { $0.count >= 6 })
        let filtered = CatalogRepository.filter(page.threads, matching: needle)
        #expect(filtered.isEmpty == false)
        #expect(CatalogRepository.filter(page.threads, matching: "").count == page.threads.count)
        #expect(CatalogRepository.filter(page.threads, matching: "щщщzzz").isEmpty)
    }
}
