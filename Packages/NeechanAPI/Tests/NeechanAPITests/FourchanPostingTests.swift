import Foundation
import NeechanAPITesting
import Testing
@testable import NeechanAPI

@Suite("4chan posting")
struct FourchanPostingTests {
    private func service(_ transport: StubTransport) -> PostingService {
        PostingService(
            client: DvachClient(transport: transport, site: { .init(site: .fourchan) }),
            transport: transport,
            site: { .init(site: .fourchan) }
        )
    }

    private func request(thread: Int? = 123, comment: String = "hello") -> PostingRequest {
        var request = PostingRequest(board: "po", thread: thread, comment: comment)
        request.captcha = .slider(challenge: "token", response: "ABCD")
        request.deletionPassword = "secret"
        return request
    }

    private func body(of transport: StubTransport) async throws -> String {
        let recorded = try #require(await transport.lastRequest())
        return String(decoding: try #require(recorded.httpBody), as: UTF8.self)
    }

    @Test("a reply goes to the board's own posting address")
    func replyAddress() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("<!-- thread:123,no:456 -->".utf8))
        _ = try await service(transport).send(request())

        let recorded = try #require(await transport.lastRequest())
        #expect(recorded.url?.absoluteString == "https://sys.4chan.org/po/post")
        #expect(recorded.httpMethod == "POST")
        // The site checks it, so it has to look like it came from the board.
        #expect(recorded.value(forHTTPHeaderField: "Referer") == "https://boards.4chan.org/po/")
    }

    @Test("the form carries the fields the site's own page sends")
    func formFields() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("<!-- thread:123,no:456 -->".utf8))
        _ = try await service(transport).send(request())

        let body = try await body(of: transport)
        #expect(body.contains(#"name="mode""#))
        #expect(body.contains("\r\n\r\nregist\r\n"))
        #expect(body.contains(#"name="MAX_FILE_SIZE""#))
        #expect(body.contains(#"name="resto""#))
        #expect(body.contains(#"name="com""#))
        #expect(body.contains(#"name="pwd""#))
    }

    /// The reader aligned the slider and typed what they saw; the two halves
    /// travel back under the names the site's own form uses.
    @Test("a solved slider captcha travels as the challenge and the response")
    func captchaFields() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("<!-- thread:123,no:456 -->".utf8))
        _ = try await service(transport).send(request())

        let body = try await body(of: transport)
        #expect(body.contains(#"name="t-challenge""#))
        #expect(body.contains("\r\n\r\ntoken\r\n"))
        #expect(body.contains(#"name="t-response""#))
        #expect(body.contains("\r\n\r\nABCD\r\n"))
    }

    @Test("starting a thread sends no thread to reply to")
    func newThreadOmitsResto() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("<!-- thread:0,no:999 -->".utf8))
        _ = try await service(transport).send(request(thread: nil))

        #expect(try await body(of: transport).contains(#"name="resto""#) == false)
    }

    @Test("a file is attached singly, under the name the form uses")
    func attachment() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("<!-- thread:123,no:456 -->".utf8))
        var post = request()
        post.attachments = [
            .init(fileName: "a.png", mimeType: "image/png", data: Data([0x89, 0x50])),
        ]
        _ = try await service(transport).send(post)

        let body = try await body(of: transport)
        #expect(body.contains(#"name="upfile""#))
        #expect(body.contains(#"filename="a.png""#))
        // 2ch's repeated `file[]` would be rejected here.
        #expect(body.contains("file[]") == false)
    }

    @Test("a reply is read out of the comment the site hides in the page")
    func successfulReply() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data("<html><body><!-- thread:123,no:456 --></body></html>".utf8)
        )
        #expect(try await service(transport).send(request()) == .posted(num: 456))
    }

    @Test("a new thread reports itself as one")
    func successfulThread() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("<!-- thread:0,no:999 -->".utf8))
        #expect(try await service(transport).send(request(thread: nil)) == .threadCreated(num: 999))
    }

    /// Mapping the site's sentences onto the codes the posting layer already
    /// understands is what keeps "ask for a fresh captcha", "offer a retry" and
    /// "stop" working without a second implementation of each.
    @Test(
        "the site's own words are classified into what the app should do",
        arguments: [
            ("You seem to have mistyped the CAPTCHA.", DvachErrorCode.invalidCaptcha, true, false),
            ("Error: You must wait longer before posting.", .postingTooFast, false, true),
            ("Error: Flood detected, post discarded.", .postingTooFast, false, true),
            ("Error: You are banned :(", .banned, false, false),
            ("Error: Our system thinks your post is spam.", .banned, false, false),
            ("Error: Thread is closed.", .threadClosed, false, false),
            ("Error: File too large.", .fileTooBig, false, false),
        ]
    )
    func errorClassification(
        message: String,
        code: DvachErrorCode,
        needsCaptcha: Bool,
        retryable: Bool
    ) async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data(#"<span id="errmsg" style="color: red;">\#(message)</span>"#.utf8)
        )
        do {
            _ = try await service(transport).send(request())
            Issue.record("a refusal should not read as a posted reply")
        } catch let error as PostingError {
            #expect(error.code == code, "\(message)")
            #expect(error.message == message)
            #expect(error.requiresNewCaptcha == needsCaptcha)
            #expect(error.isRetryable == retryable)
        }
    }

    @Test("an unrecognised refusal is reported in the site's own words")
    func unknownError() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data(#"<span id="errmsg">Something new went wrong.</span>"#.utf8)
        )
        do {
            _ = try await service(transport).send(request())
            Issue.record("expected a refusal")
        } catch let error as PostingError {
            #expect(error.message == "Something new went wrong.")
            // Nothing is guessed at: an unknown refusal is not marked retryable.
            #expect(error.isRetryable == false)
            #expect(error.isTerminal == false)
        }
    }

    /// The post never reached the site, so the reader is asked to pass the
    /// check rather than told their post was refused.
    @Test("a browser check is not reported as a rejected post")
    func browserCheck() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data("<html>Just a moment</html>".utf8),
            statusCode: 403,
            headers: ["cf-mitigated": "challenge", "content-type": "text/html"]
        )
        do {
            _ = try await service(transport).send(request())
            Issue.record("expected the browser check to be reported")
        } catch let error as PostingError {
            #expect(error.message.lowercased().contains("browser"))
        }
    }

    @Test("a page with neither an outcome nor an error is not read as success")
    func silentPage() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("<html><body>hello</body></html>".utf8))
        await #expect(throws: PostingError.self) {
            _ = try await service(transport).send(request())
        }
    }

    @Test("the reply parser finds the numbers wherever they sit in the page")
    func numberParsing() {
        #expect(FourchanPostingReply.numbers(in: "<!-- thread:1,no:2 -->")?.thread == 1)
        #expect(FourchanPostingReply.numbers(in: "<!-- thread:1,no:2 -->")?.post == 2)
        #expect(FourchanPostingReply.numbers(in: "nothing here") == nil)
    }
}
