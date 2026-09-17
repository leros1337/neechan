import Foundation
import Testing
@testable import NeechanAPI

@Suite("4chan endpoints")
struct FourchanEndpointTests {
    private let fourchan = SiteSelection(site: .fourchan)

    private func url(_ endpoint: ImageboardEndpoint) throws -> String {
        try #require(endpoint.request(for: fourchan)?.url?.absoluteString)
    }

    @Test("the read endpoints are static files on the API host")
    func readEndpoints() throws {
        #expect(try url(.boards) == "https://a.4cdn.org/boards.json")
        #expect(try url(.catalog(board: "g")) == "https://a.4cdn.org/g/catalog.json")
        #expect(try url(.thread(board: "g", thread: 1)) == "https://a.4cdn.org/g/thread/1.json")
        #expect(try url(.boardThreads(board: "g")) == "https://a.4cdn.org/g/threads.json")
        #expect(try url(.archiveIndex(board: "g")) == "https://a.4cdn.org/g/archive.json")
    }

    /// 4chan has no `index.json`, and `/g/0.json` is a genuine 404.
    @Test("index pages start at one, not at an index file")
    func indexPagesStartAtOne() throws {
        #expect(try url(.boardPage(board: "g", page: 0)) == "https://a.4cdn.org/g/1.json")
        #expect(try url(.boardPage(board: "g", page: 1)) == "https://a.4cdn.org/g/1.json")
        #expect(try url(.boardPage(board: "g", page: 3)) == "https://a.4cdn.org/g/3.json")

        // 2ch is unchanged: its page zero is a file of its own.
        let dvach = ImageboardEndpoint.boardPage(board: "po", page: 0)
            .request(for: .default)?.url?.absoluteString
        #expect(dvach == "https://2ch.org/po/index.json")
    }

    @Test("an ordering the site does not offer falls back to the one it does")
    func catalogByCreationFallsBack() throws {
        #expect(try url(.catalogByCreation(board: "g")) == "https://a.4cdn.org/g/catalog.json")
    }

    @Test("an archived thread is read from the ordinary thread endpoint")
    func archivedThread() throws {
        #expect(try url(.archiveThread(board: "g", thread: 7)) == "https://a.4cdn.org/g/thread/7.json")
    }

    @Test("the captcha is asked for on the posting host")
    func captchaEndpoint() throws {
        #expect(
            try url(.sliderCaptcha(board: "g", thread: 1))
                == "https://sys.4chan.org/captcha?board=g&thread_id=1"
        )
        #expect(try url(.sliderCaptcha(board: "g", thread: nil)) == "https://sys.4chan.org/captcha?board=g")
    }

    /// Nothing is guessed at: an endpoint the site does not serve builds no
    /// request at all, and the client turns that into a refusal.
    @Test("an endpoint 4chan does not serve is refused, not invented")
    func unsupportedEndpointsBuildNothing() {
        let unsupported: [ImageboardEndpoint] = [
            .after(board: "g", thread: 1, sinceNum: 1),
            .threadInfo(board: "g", thread: 1),
            .search(board: "g", text: "swift"),
            .like(board: "g", num: 1),
            .dislike(board: "g", num: 1),
            .report(board: "g", thread: 1, posts: [1], comment: ""),
            .passcodeLogin(passcode: "x"),
            .captchaSettings(board: "g"),
            .emojiCaptchaID(board: "g", thread: nil),
        ]
        for endpoint in unsupported {
            #expect(endpoint.request(for: fourchan) == nil, "\(endpoint) should build nothing")
        }
    }

    @Test("2ch is not asked for the endpoints only 4chan has")
    func dvachHasNoFourchanEndpoints() {
        #expect(ImageboardEndpoint.boardThreads(board: "b").request(for: .default) == nil)
        #expect(ImageboardEndpoint.sliderCaptcha(board: "b", thread: nil).request(for: .default) == nil)
    }

    /// Counter-intuitive, and deliberate: `a.4cdn.org` sends `max-age=5` and an
    /// ETag, so leaving the default policy alone lets the session answer a
    /// repeat from its own cache with no request at all — which is the pacing
    /// the site's rules ask for, free. 2ch sends no validators, which is why
    /// revalidation is forced there.
    @Test("4chan reads are left to the site's own cache headers")
    func cachePolicy() throws {
        let fourchanThread = try #require(
            ImageboardEndpoint.thread(board: "g", thread: 1).request(for: fourchan)
        )
        #expect(fourchanThread.cachePolicy == .useProtocolCachePolicy)

        let dvachPoll = try #require(
            ImageboardEndpoint.threadInfo(board: "b", thread: 1).request(for: .default)
        )
        #expect(dvachPoll.cachePolicy == .reloadRevalidatingCacheData)
    }

    @Test("a whole-board poll gives up as quickly as any other poll")
    func boardPollTimesOutSooner() throws {
        let poll = try #require(
            ImageboardEndpoint.boardThreads(board: "g").request(for: fourchan)
        )
        #expect(poll.timeoutInterval == 15)
    }

    @Test("a board code from the search box cannot climb out of its path")
    func boardCodesAreEscaped() throws {
        let escaped = try url(.catalog(board: "a b/../c"))
        #expect(escaped.contains("..") == false)
        #expect(escaped.hasPrefix("https://a.4cdn.org/"))
    }
}
