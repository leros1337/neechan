import Foundation
import NeechanAPITesting
import Testing
@testable import NeechanAPI

/// Sending a post the way the site's quick reply does.
///
/// Every post here goes through a stand-in for the browser engine, because the
/// posting host refuses anything else; the app's own transport is there to
/// prove it is never touched. Nothing here ever reaches the site.
@Suite("4chan posting")
struct FourchanPostingTests {
    /// A browser answering every post with `reply`, and a transport that must
    /// stay unused.
    private func service(
        replying reply: HTTPReply? = nil
    ) async -> (PostingService, FakeFourchanBrowser, StubTransport) {
        let transport = StubTransport()
        let browser = FakeFourchanBrowser()
        if let reply { await browser.queuePost(reply) }
        let slot = FourchanBrowserSlot()
        slot.install(browser)
        let service = PostingService(
            client: DvachClient(transport: transport, site: { .init(site: .fourchan) }),
            transport: transport,
            site: { .init(site: .fourchan) },
            browser: slot
        )
        return (service, browser, transport)
    }

    private func html(_ body: String, statusCode: Int = 200) -> HTTPReply {
        HTTPReply(data: Data(body.utf8), statusCode: statusCode, headers: ["content-type": "text/html"])
    }

    private func json(_ body: String) -> HTTPReply {
        HTTPReply(data: Data(body.utf8), statusCode: 200, headers: ["content-type": "application/json"])
    }

    private func request(thread: Int? = 123, comment: String = "hello") -> PostingRequest {
        var request = PostingRequest(board: "po", thread: thread, comment: comment)
        request.captcha = .slider(challenge: "token", response: "2031")
        request.deletionPassword = "secret"
        return request
    }

    private func body(of browser: FakeFourchanBrowser) async throws -> String {
        let recorded = try #require(await browser.posts.last)
        return String(decoding: try #require(recorded.request.httpBody), as: UTF8.self)
    }

    @Test("a reply goes to the board's own posting address, from the thread's page")
    func replyAddress() async throws {
        let (service, browser, transport) = await service(replying: json(#"{"tid":123,"pid":456}"#))
        _ = try await service.send(request())

        let recorded = try #require(await browser.posts.last)
        #expect(recorded.request.url?.absoluteString == "https://sys.4chan.org/po/post")
        #expect(recorded.request.httpMethod == "POST")
        #expect(recorded.page.absoluteString == "https://boards.4chan.org/po/thread/123")
        // As the quick reply asks; the page supplies the Referer itself.
        #expect(recorded.request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(recorded.request.value(forHTTPHeaderField: "Referer") == nil)
        // The posting host's gates refuse the app's own requests.
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("a new thread is sent from the board's page")
    func newThreadPage() async throws {
        let (service, browser, _) = await service(replying: json(#"{"tid":999,"pid":999}"#))
        _ = try await service.send(request(thread: nil))
        #expect(await browser.posts.last?.page.absoluteString == "https://boards.4chan.org/po/")
    }

    @Test("the form carries the fields the site's own page sends")
    func formFields() async throws {
        let (service, browser, _) = await service(replying: html("<!-- thread:123,no:456 -->"))
        _ = try await service.send(request())

        let body = try await body(of: browser)
        #expect(body.contains(#"name="mode""#))
        #expect(body.contains("\r\n\r\nregist\r\n"))
        #expect(body.contains(#"name="MAX_FILE_SIZE""#))
        #expect(body.contains(#"name="resto""#))
        #expect(body.contains(#"name="com""#))
        #expect(body.contains(#"name="pwd""#))
    }

    /// The positions the reader picked, one per step, travel back beside the
    /// challenge under the names the site's own form uses.
    @Test("an answered captcha travels as the challenge and the response")
    func captchaFields() async throws {
        let (service, browser, _) = await service(replying: html("<!-- thread:123,no:456 -->"))
        _ = try await service.send(request())

        let body = try await body(of: browser)
        #expect(body.contains(#"name="t-challenge""#))
        #expect(body.contains("\r\n\r\ntoken\r\n"))
        #expect(body.contains(#"name="t-response""#))
        #expect(body.contains("\r\n\r\n2031\r\n"))
    }

    @Test("starting a thread sends no thread to reply to")
    func newThreadOmitsResto() async throws {
        let (service, browser, _) = await service(replying: html("<!-- thread:0,no:999 -->"))
        _ = try await service.send(request(thread: nil))

        #expect(try await body(of: browser).contains(#"name="resto""#) == false)
    }

    @Test("a file is attached singly, under the name the form uses")
    func attachment() async throws {
        let (service, browser, _) = await service(replying: html("<!-- thread:123,no:456 -->"))
        var post = request()
        post.attachments = [
            .init(fileName: "a.png", mimeType: "image/png", data: Data([0x89, 0x50])),
        ]
        _ = try await service.send(post)

        let body = try await body(of: browser)
        #expect(body.contains(#"name="upfile""#))
        #expect(body.contains(#"filename="a.png""#))
        // 2ch's repeated `file[]` would be rejected here.
        #expect(body.contains("file[]") == false)
    }

    @Test("a reply is read out of the comment the site hides in the page")
    func successfulReply() async throws {
        let (service, _, _) = await service(
            replying: html("<html><body><!-- thread:123,no:456 --></body></html>")
        )
        #expect(try await service.send(request()) == .posted(num: 456))
    }

    @Test("a new thread reports itself as one")
    func successfulThread() async throws {
        let (service, _, _) = await service(replying: html("<!-- thread:0,no:999 -->"))
        #expect(try await service.send(request(thread: nil)) == .threadCreated(num: 999))
    }

    @Test("the quick reply's answer is read: a reply, and a new thread")
    func jsonSuccess() async throws {
        let (reply, _, _) = await service(replying: json(#"{"tid":123,"pid":456}"#))
        #expect(try await reply.send(request()) == .posted(num: 456))

        let (thread, _, _) = await service(replying: json(#"{"tid":999,"pid":999}"#))
        #expect(try await thread.send(request(thread: nil)) == .threadCreated(num: 999))
    }

    @Test("the quick reply's refusal is read in the site's words, without its markup")
    func jsonRefusal() async throws {
        let (service, _, _) = await service(
            replying: json(##"{"error":"Error: You seem to have mistyped the CAPTCHA. <a href=\"#\">Retry</a>"}"##)
        )
        do {
            _ = try await service.send(request())
            Issue.record("a refusal should not read as a posted reply")
        } catch let error as PostingError {
            #expect(error.code == .invalidCaptcha)
            #expect(error.message == "Error: You seem to have mistyped the CAPTCHA. Retry")
        }
    }

    /// The request left, and nothing readable came back. Saying it was not
    /// sent would invite a second, duplicate post.
    @Test("a post that left but was never answered is not called unsent")
    func unconfirmed() async throws {
        let (service, browser, _) = await service()
        await browser.queuePostFailure(.unconfirmed("TypeError: Load failed"))
        do {
            _ = try await service.send(request())
            Issue.record("expected a failure")
        } catch let error as PostingError {
            #expect(error.message.contains("may have gone through"))
            #expect(error.isRetryable == false)
        }
    }

    @Test("without the browser engine nothing is sent, and it says why")
    func noBrowser() async throws {
        let transport = StubTransport()
        let service = PostingService(
            client: DvachClient(transport: transport, site: { .init(site: .fourchan) }),
            transport: transport,
            site: { .init(site: .fourchan) },
            browser: FourchanBrowserSlot()
        )
        await #expect(throws: PostingError.self) {
            _ = try await service.send(request())
        }
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("a failed status with nothing to say is reported as that status")
    func bareFailure() async throws {
        let (service, _, _) = await service(replying: html("<html><body></body></html>", statusCode: 500))
        do {
            _ = try await service.send(request())
            Issue.record("expected a failure")
        } catch let error as PostingError {
            #expect(error.code == .unknown(500))
            #expect(error.message.contains("500"))
        }
    }

    /// Mapping the site's sentences onto the codes the posting layer already
    /// understands is what keeps "ask for a fresh captcha", "offer a retry" and
    /// "stop" working without a second implementation of each.
    @Test(
        "the site's own words are classified into what the app should do",
        arguments: [
            ("You seem to have mistyped the CAPTCHA.", DvachErrorCode.invalidCaptcha, true, false),
            ("You have to wait a while before doing this again.", .rateLimited, true, true),
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
        let (service, _, _) = await service(
            replying: html(#"<span id="errmsg" style="color: red;">\#(message)</span>"#)
        )
        do {
            _ = try await service.send(request())
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
        let (service, _, _) = await service(
            replying: html(#"<span id="errmsg">Something new went wrong.</span>"#)
        )
        do {
            _ = try await service.send(request())
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
        let (service, _, _) = await service(
            replying: HTTPReply(
                data: Data("<html>Just a moment</html>".utf8),
                statusCode: 403,
                headers: ["cf-mitigated": "challenge", "content-type": "text/html"]
            )
        )
        do {
            _ = try await service.send(request())
            Issue.record("expected the browser check to be reported")
        } catch let error as PostingError {
            #expect(error.message.lowercased().contains("browser"))
        }
    }

    @Test("a page with neither an outcome nor an error is not read as success")
    func silentPage() async throws {
        let (service, _, _) = await service(replying: html("<html><body>hello</body></html>"))
        await #expect(throws: PostingError.self) {
            _ = try await service.send(request())
        }
    }

    @Test("the reply parser finds the numbers wherever they sit in the page")
    func numberParsing() {
        #expect(FourchanPostingReply.numbers(in: "<!-- thread:1,no:2 -->")?.thread == 1)
        #expect(FourchanPostingReply.numbers(in: "<!-- thread:1,no:2 -->")?.post == 2)
        #expect(FourchanPostingReply.numbers(in: "nothing here") == nil)
    }
}
