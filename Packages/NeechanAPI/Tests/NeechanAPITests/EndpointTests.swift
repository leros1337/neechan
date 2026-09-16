import Foundation
import Testing
@testable import NeechanAPI

@Suite("Endpoints")
struct EndpointTests {
    private func url(_ endpoint: DvachEndpoint, on domain: DvachDomain = .org) throws -> String {
        try #require(endpoint.request(on: domain).url?.absoluteString)
    }

    @Test("the board list uses the mobile API")
    func boardsURL() throws {
        #expect(try url(.boards) == "https://2ch.org/api/mobile/v2/boards")
    }

    @Test("every endpoint follows the selected mirror")
    func mirrorIsHonoured() throws {
        #expect(try url(.boards, on: .life) == "https://2ch.life/api/mobile/v2/boards")
        #expect(try url(.catalog(board: "b"), on: .life) == "https://2ch.life/b/catalog.json")
    }

    @Test("catalog ordering picks a different file")
    func catalogOrdering() throws {
        #expect(try url(.catalog(board: "b")) == "https://2ch.org/b/catalog.json")
        #expect(try url(.catalogByCreation(board: "b")) == "https://2ch.org/b/catalog_num.json")
    }

    @Test("page zero is the index, later pages are numbered")
    func pagedIndex() throws {
        #expect(try url(.boardPage(board: "po", page: 0)) == "https://2ch.org/po/index.json")
        #expect(try url(.boardPage(board: "po", page: 1)) == "https://2ch.org/po/1.json")
        #expect(try url(.boardPage(board: "po", page: 12)) == "https://2ch.org/po/12.json")
    }

    @Test("a thread is addressed by its number")
    func threadURL() throws {
        #expect(try url(.thread(board: "b", thread: 123)) == "https://2ch.org/b/res/123.json")
    }

    @Test("the incremental endpoint carries board, thread and anchor")
    func afterURL() throws {
        #expect(
            try url(.after(board: "b", thread: 123, sinceNum: 456))
                == "https://2ch.org/api/mobile/v2/after/b/123/456"
        )
    }

    @Test("the watcher poll and single-post lookup use the mobile API")
    func mobileLookups() throws {
        #expect(try url(.threadInfo(board: "b", thread: 7)) == "https://2ch.org/api/mobile/v2/info/b/7")
        #expect(try url(.post(board: "b", num: 7)) == "https://2ch.org/api/mobile/v2/post/b/7")
    }

    @Test("archive endpoints sit under the board's arch directory")
    func archiveURLs() throws {
        #expect(try url(.archiveIndex(board: "b")) == "https://2ch.org/b/arch/index.json")
        #expect(try url(.archivePage(board: "b", page: 3)) == "https://2ch.org/b/arch/3.json")
        #expect(try url(.archiveThread(board: "b", thread: 99)) == "https://2ch.org/b/arch/res/99.json")
    }

    @Test("voting endpoints pass the board and post as query items")
    func voteURLs() throws {
        #expect(try url(.like(board: "news", num: 5)) == "https://2ch.org/api/like?board=news&num=5")
        #expect(try url(.dislike(board: "news", num: 5)) == "https://2ch.org/api/dislike?board=news&num=5")
    }

    @Test("read endpoints are GETs that ask for JSON")
    func readRequestsAreGETs() throws {
        for endpoint: DvachEndpoint in [
            .boards, .catalog(board: "b"), .boardPage(board: "b", page: 0),
            .thread(board: "b", thread: 1), .after(board: "b", thread: 1, sinceNum: 1),
            .threadInfo(board: "b", thread: 1), .post(board: "b", num: 1)
        ] {
            let request = endpoint.request(on: .org)
            #expect(request.httpMethod == "GET", "\(endpoint) should be a GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.httpBody == nil)
        }
    }

    @Test("search posts a multipart form and asks for a JSON reply")
    func searchRequest() throws {
        let request = DvachEndpoint.search(board: "b", text: "аниме").request(on: .org)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://2ch.org/user/search?json=1")

        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains(#"name="board""#))
        #expect(body.contains("\r\n\r\nb\r\n"))
        #expect(body.contains(#"name="text""#))
        #expect(body.contains("аниме"))
    }

    @Test("a board code with unsafe characters is percent-encoded, not injected")
    func boardCodeIsEscaped() throws {
        let escaped = try url(.catalog(board: "a b/../c"))
        #expect(escaped.contains("..") == false)
        #expect(escaped.hasPrefix("https://2ch.org/"))
    }

    @Test("negative and zero identifiers do not produce a traversal")
    func numericPathsAreSafe() throws {
        #expect(try url(.thread(board: "b", thread: 0)) == "https://2ch.org/b/res/0.json")
        #expect(try url(.boardPage(board: "b", page: -1)) == "https://2ch.org/b/index.json")
    }
}

@Suite("Polling requests")
struct PollEndpointTests {
    @Test("a polled endpoint gives up sooner than one the reader is waiting on")
    func pollsTimeOutSooner() {
        let poll = DvachEndpoint.threadInfo(board: "b", thread: 1).request(on: .org)
        let incremental = DvachEndpoint.after(board: "b", thread: 1, sinceNum: 5).request(on: .org)
        let reader = DvachEndpoint.thread(board: "b", thread: 1).request(on: .org)

        #expect(poll.timeoutInterval == 15)
        #expect(incremental.timeoutInterval == 15)
        #expect(reader.timeoutInterval > 15)
    }

    /// Where the server sends validators this turns a repeated poll into a 304
    /// and no body; where it does not, it costs nothing.
    @Test("a polled endpoint asks the server to confirm rather than resend")
    func pollsRevalidate() {
        let poll = DvachEndpoint.threadInfo(board: "b", thread: 1).request(on: .org)
        let reader = DvachEndpoint.thread(board: "b", thread: 1).request(on: .org)

        #expect(poll.cachePolicy == .reloadRevalidatingCacheData)
        #expect(reader.cachePolicy == .useProtocolCachePolicy)
    }
}
