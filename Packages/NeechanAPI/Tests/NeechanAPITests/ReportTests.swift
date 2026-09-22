import Foundation
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

@Suite("Reporting")
struct ReportTests {
    private let dvach = SiteSelection(site: .dvach, mirror: .org)

    private func makeClient(_ transport: StubTransport) -> DvachClient {
        DvachClient(transport: transport, site: { .init(site: .dvach, mirror: .org) })
    }

    // MARK: The request

    @Test("a report posts a multipart form to /user/report")
    func reportRequest() throws {
        let request = try #require(
            ImageboardEndpoint
                .report(board: "b", thread: 123, posts: [456], comment: "спам")
                .request(for: dvach)
        )

        #expect(request.httpMethod == "POST")
        // No `json=1`: unlike search and passlogin, the site answers this one
        // as JSON without being asked.
        #expect(request.url?.absoluteString == "https://2ch.org/user/report")

        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains(#"name="board""#))
        #expect(body.contains("\r\n\r\nb\r\n"))
        #expect(body.contains(#"name="thread""#))
        #expect(body.contains("\r\n\r\n123\r\n"))
        #expect(body.contains(#"name="comment""#))
        #expect(body.contains("спам"))
    }

    /// The site takes an array by being told the same name more than once,
    /// which is the one thing `URLComponents` could not have expressed.
    @Test("several posts are sent as a repeated field, not a joined string")
    func severalPosts() throws {
        let request = try #require(
            ImageboardEndpoint
                .report(board: "b", thread: 1, posts: [2, 3], comment: "x")
                .request(for: dvach)
        )
        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })

        #expect(body.components(separatedBy: #"name="post""#).count == 3)
        #expect(body.contains("\r\n\r\n2\r\n"))
        #expect(body.contains("\r\n\r\n3\r\n"))
    }

    /// 4chan answers a report with a page, not an endpoint, so there is nothing
    /// for the client to build. `SiteLinks.report` is what serves that site.
    @Test("4chan builds no report request at all")
    func fourchanHasNoReportEndpoint() {
        let endpoint = ImageboardEndpoint.report(board: "g", thread: 1, posts: [1], comment: "x")
        #expect(endpoint.request(for: SiteSelection(site: .fourchan)) == nil)
    }

    // MARK: The service

    @Test("a report the site accepts returns without complaint")
    func reportSucceeds() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/report", data: try FixtureLoader.data(.reportOK))
        let service = ReportService(client: makeClient(transport))

        try await service.report(board: "b", thread: 123, posts: [456], comment: "спам")

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.path() == "/user/report")
    }

    /// -52 is the one a reader meets in ordinary use: they reported a post, and
    /// then reported it again. The site's own sentence is what reaches them,
    /// which is why the error is raised rather than swallowed.
    @Test("a second report on the same post is refused, in the site's words")
    func reportAlreadySent() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/user/report", data: try FixtureLoader.data(.reportAlreadySent)
        )
        let service = ReportService(client: makeClient(transport))

        do {
            try await service.report(board: "b", thread: 123, posts: [456], comment: "спам")
            Issue.record("the refusal was not raised")
        } catch {
            #expect(error.code == .reportAlreadySent)
            #expect(error.serverMessage == "Вы уже отправляли жалобу на этот пост.")
        }
    }
}
