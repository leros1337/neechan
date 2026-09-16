import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanCore

@Suite("Cookie manager")
struct CookieManagerTests {
    /// Cookie storage is process-wide, so each test gets its own container and
    /// clears up after itself.
    private func makeStorage() -> HTTPCookieStorage {
        HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "neechan.tests.\(UUID().uuidString)"
        )
    }

    private func makeCookie(
        name: String,
        value: String = "v",
        domain: DvachDomain = .org
    ) throws -> HTTPCookie {
        try #require(
            HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: domain.baseURL.host() ?? "",
                .path: "/",
                .originURL: domain.baseURL,
            ])
        )
    }

    @Test("what the site set is listed back")
    func listsCookies() async throws {
        let storage = makeStorage()
        storage.setCookie(try makeCookie(name: "ageallow", value: "1"))
        let manager = CookieManager(storage: storage, domain: { .org })

        let cookies = await manager.cookies()
        #expect(cookies.map(\.name) == ["ageallow"])
        #expect(cookies.first?.value == "1")
    }

    @Test("the cookies that carry a session are marked as such")
    func marksSignificantCookies() async throws {
        let storage = makeStorage()
        storage.setCookie(try makeCookie(name: "passcode_auth"))
        storage.setCookie(try makeCookie(name: "_ym_uid"))
        let manager = CookieManager(storage: storage, domain: { .org })

        let cookies = await manager.cookies()
        let significant = cookies.filter(\.isSignificant).map(\.name)
        #expect(significant == ["passcode_auth"])
    }

    @Test("a deleted cookie is gone")
    func removesOne() async throws {
        let storage = makeStorage()
        storage.setCookie(try makeCookie(name: "ageallow"))
        storage.setCookie(try makeCookie(name: "passcode_auth"))
        let manager = CookieManager(storage: storage, domain: { .org })

        let host = try #require(DvachDomain.org.baseURL.host())
        await manager.remove(name: "ageallow", domain: host)

        #expect(await manager.cookies().map(\.name) == ["passcode_auth"])
    }

    /// The session lives on cookies pinned to a host, so switching mirrors has
    /// to carry the reader's own across or they are signed out by the switch.
    @Test("a mirror switch carries the passcode and the age confirmation over")
    func mirrorsPortableCookies() async throws {
        let storage = makeStorage()
        storage.setCookie(try makeCookie(name: "passcode_auth", value: "abc"))
        storage.setCookie(try makeCookie(name: "ageallow", value: "1"))
        storage.setCookie(try makeCookie(name: "_ym_uid", value: "junk"))
        let manager = CookieManager(storage: storage, domain: { .org })

        await manager.mirror(names: CookieManager.portableCookieNames, to: .life)

        let moved = storage.cookies(for: DvachDomain.life.baseURL) ?? []
        #expect(Set(moved.map(\.name)) == ["passcode_auth", "ageallow"])
        #expect(moved.first { $0.name == "passcode_auth" }?.value == "abc")
    }

    @Test("cookies a browser check produced are taken over")
    func adoptsWebViewCookies() async throws {
        let storage = makeStorage()
        let manager = CookieManager(storage: storage, domain: { .org })

        await manager.adopt([try makeCookie(name: "cf_clearance", value: "token")])

        #expect(await manager.cookies().map(\.name) == ["cf_clearance"])
    }

    @Test("clearing takes everything")
    func removesAll() async throws {
        let storage = makeStorage()
        storage.setCookie(try makeCookie(name: "ageallow"))
        storage.setCookie(try makeCookie(name: "passcode_auth", domain: .life))
        let manager = CookieManager(storage: storage, domain: { .org })

        await manager.removeAll()
        #expect(await manager.cookies().isEmpty)
    }
}

@Suite("Server search")
struct SearchServiceTests {
    private func makeClient(_ transport: StubTransport) -> DvachClient {
        DvachClient(transport: transport, domain: { .org })
    }

    @Test("a search returns the posts the site found")
    func returnsPosts() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/search", data: try FixtureLoader.data(.searchResult))
        let service = SearchService(client: makeClient(transport))

        let posts = try await service.search(board: "b", text: "тест")
        #expect(posts.isEmpty == false)
    }

    /// The site answers a short query with error -23; refusing it here saves a
    /// round trip and gives a message that says what to do.
    @Test("a query too short to search is refused before it is sent")
    func refusesShortQueries() async throws {
        let transport = StubTransport()
        let service = SearchService(client: makeClient(transport))

        await #expect(throws: SearchService.SearchError.queryTooShort(minimum: 3)) {
            try await service.search(board: "b", text: "ab")
        }
        #expect(await transport.recordedRequests().isEmpty, "nothing should have been sent")
    }

    @Test("the site's own refusal of a short query is reported the same way")
    func mapsServerShortQueryError() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/user/search", data: try FixtureLoader.data(.searchTooShort)
        )
        let service = SearchService(client: makeClient(transport))

        await #expect(throws: SearchService.SearchError.queryTooShort(minimum: 3)) {
            try await service.search(board: "b", text: "длинный запрос")
        }
    }
}

@Suite("Archive")
struct ArchiveRepositoryTests {
    private func makeClient(_ transport: StubTransport) -> DvachClient {
        DvachClient(transport: transport, domain: { .org })
    }

    @Test("the index page lists archived threads and knows there is more")
    func loadsIndex() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/arch/index.json", data: try FixtureLoader.data(.archiveIndex)
        )
        let repository = ArchiveRepository(client: makeClient(transport))

        let page = try await repository.page(board: "a")
        #expect(page.threads.isEmpty == false)
        #expect(page.currentPage == 0)
        #expect(page.hasNextPage)
    }

    @Test("a later page is asked for by number, not from the index")
    func laterPagesUseTheirOwnPath() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/arch/2.json", data: try FixtureLoader.data(.archiveIndex)
        )
        let repository = ArchiveRepository(client: makeClient(transport))

        _ = try await repository.page(board: "a", page: 2)
        let urls = await transport.requestedURLs()
        #expect(urls.first?.hasSuffix("/a/arch/2.json") == true)
    }
}
