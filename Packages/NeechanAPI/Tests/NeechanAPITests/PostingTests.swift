import Foundation
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

@Suite("Multipart encoder")
struct MultipartFormEncoderTests {
    private func body(_ build: (inout MultipartFormEncoder) -> Void) -> String {
        var encoder = MultipartFormEncoder(boundary: "TESTBOUNDARY")
        build(&encoder)
        return String(decoding: encoder.finalizedBody(), as: UTF8.self)
    }

    @Test("a text field is written with its name and value")
    func textField() {
        let output = body { $0.addField("board", "test") }
        #expect(output.contains(#"Content-Disposition: form-data; name="board""#))
        #expect(output.contains("\r\n\r\ntest\r\n"))
    }

    @Test("the body is closed with the terminating boundary")
    func terminates() {
        #expect(body { $0.addField("a", "b") }.hasSuffix("--TESTBOUNDARY--\r\n"))
    }

    @Test("a repeated name sends an array, which is how files are attached")
    func repeatedNames() {
        let output = body {
            $0.addFile("file[]", fileName: "a.jpg", mimeType: "image/jpeg", data: Data([1]))
            $0.addFile("file[]", fileName: "b.jpg", mimeType: "image/jpeg", data: Data([2]))
        }
        #expect(output.components(separatedBy: #"name="file[]""#).count == 3)
        #expect(output.contains(#"filename="a.jpg""#))
        #expect(output.contains(#"filename="b.jpg""#))
    }

    @Test("a file part declares its media type")
    func fileContentType() {
        let output = body {
            $0.addFile("file[]", fileName: "clip.webm", mimeType: "video/webm", data: Data([1]))
        }
        #expect(output.contains("Content-Type: video/webm"))
    }

    @Test("a quote in a file name cannot break out of the header")
    func escapesQuotes() {
        let output = body {
            $0.addFile("file[]", fileName: #"a"b.jpg"#, mimeType: "image/jpeg", data: Data())
        }
        #expect(output.contains(#"filename="a%22b.jpg""#))
    }

    @Test("a newline in a field name cannot inject a header")
    func stripsNewlines() {
        let output = body { $0.addField("a\r\nX-Evil: 1", "v") }
        #expect(output.contains("X-Evil") == false || output.contains("name=\"aX-Evil: 1\""))
    }

    @Test("binary content survives unchanged")
    func binaryIsIntact() {
        var encoder = MultipartFormEncoder(boundary: "B")
        let payload = Data([0x00, 0xFF, 0x0D, 0x0A, 0x42])
        encoder.addFile("file[]", fileName: "x.bin", mimeType: "application/octet-stream", data: payload)
        #expect(encoder.finalizedBody().range(of: payload) != nil)
    }
}

@Suite("Posting service")
struct PostingServiceTests {
    private func makeService(_ transport: StubTransport) -> PostingService {
        PostingService(
            client: DvachClient(transport: transport, site: { .init(site: .dvach, mirror: .org) }),
            transport: transport,
            site: { .init(site: .dvach, mirror: .org) }
        )
    }

    private func draft(
        board: String = "test",
        thread: Int? = nil,
        comment: String = "привет"
    ) -> PostingRequest {
        PostingRequest(
            board: board,
            thread: thread,
            comment: comment,
            captcha: .emoji(token: "captcha-token", proofOfWork: 1234)
        )
    }

    // MARK: Request shape

    @Test("a reply names the board, the thread and the captcha")
    func replyRequestShape() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))
        _ = try await makeService(transport).send(draft(thread: 4242))

        let request = try #require(await transport.lastRequest())
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.contains("/user/posting") == true)
        #expect(body.contains("\r\n\r\npost\r\n"), "task=post is required")
        #expect(body.contains("\r\n\r\ntest\r\n"))
        #expect(body.contains("\r\n\r\n4242\r\n"))
        #expect(body.contains("emoji_captcha"))
        #expect(body.contains("captcha-token"))
        #expect(body.contains("2ch_challenge"))
        #expect(body.contains("\r\n\r\n1234\r\n"))
    }

    @Test("a new thread is posted with thread zero")
    func newThreadUsesZero() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingThreadOK))
        _ = try await makeService(transport).send(draft(thread: nil))

        let body = String(
            decoding: try #require(await transport.lastRequest()?.httpBody), as: UTF8.self
        )
        #expect(body.contains(#"name="thread""#))
        #expect(body.contains("\r\n\r\n0\r\n"))
    }

    @Test("optional fields are sent only when filled in")
    func omitsEmptyFields() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))
        _ = try await makeService(transport).send(draft())

        let body = String(
            decoding: try #require(await transport.lastRequest()?.httpBody), as: UTF8.self
        )
        #expect(body.contains(#"name="subject""#) == false)
        #expect(body.contains(#"name="email""#) == false)
        #expect(body.contains(#"name="op_mark""#) == false)
    }

    @Test("sage, op mark, name and subject are sent when set")
    func sendsOptionalFields() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))

        var request = draft(thread: 1)
        request.subject = "Тема"
        request.name = "Аноним#trip"
        request.isSage = true
        request.isOriginalPoster = true
        _ = try await makeService(transport).send(request)

        let body = String(
            decoding: try #require(await transport.lastRequest()?.httpBody), as: UTF8.self
        )
        #expect(body.contains("Тема"))
        #expect(body.contains("Аноним#trip"))
        // The site reads sage from the email field, as the web form does.
        #expect(body.contains(#"name="email""#))
        #expect(body.contains("\r\n\r\nsage\r\n"))
        #expect(body.contains(#"name="op_mark""#))
    }

    @Test("attachments are sent as a repeated file array")
    func sendsAttachments() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))

        var request = draft(thread: 1)
        request.attachments = [
            PostingRequest.Attachment(fileName: "a.jpg", mimeType: "image/jpeg", data: Data([1, 2])),
            PostingRequest.Attachment(fileName: "b.png", mimeType: "image/png", data: Data([3, 4])),
        ]
        _ = try await makeService(transport).send(request)

        let body = String(
            decoding: try #require(await transport.lastRequest()?.httpBody), as: UTF8.self
        )
        #expect(body.components(separatedBy: #"name="file[]""#).count == 3)
        #expect(body.contains(#"filename="a.jpg""#))
        #expect(body.contains(#"filename="b.png""#))
    }

    @Test("a passcode post declares the passcode captcha type and no token")
    func passcodePosting() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))

        var request = draft(thread: 1)
        request.captcha = .passcode
        _ = try await makeService(transport).send(request)

        let body = String(
            decoding: try #require(await transport.lastRequest()?.httpBody), as: UTF8.self
        )
        #expect(body.contains("\r\n\r\npasscode\r\n"))
        #expect(body.contains("emoji_captcha_id") == false)
    }

    // MARK: Responses

    @Test("a successful reply reports its post number")
    func parsesPostNumber() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingPostOK))

        let outcome = try await makeService(transport).send(draft(thread: 1))
        guard case .posted(let num) = outcome else {
            Issue.record("expected a post number, got \(outcome)")
            return
        }
        #expect(num > 0)
    }

    @Test("a created thread reports its thread number")
    func parsesThreadNumber() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingThreadOK))

        let outcome = try await makeService(transport).send(draft())
        guard case .threadCreated(let num) = outcome else {
            Issue.record("expected a thread number, got \(outcome)")
            return
        }
        #expect(num > 0)
    }

    @Test("an invalid captcha is reported as such, so the form can reload it")
    func mapsCaptchaError() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingErrorCaptcha)
        )
        let service = makeService(transport)

        let error = await #expect(throws: PostingError.self) {
            _ = try await service.send(draft(thread: 1))
        }
        #expect(error?.code == .invalidCaptcha)
        #expect(error?.requiresNewCaptcha == true)
    }

    @Test("a ban keeps the site's own wording, which carries the reason")
    func mapsBan() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingErrorBanned)
        )
        let service = makeService(transport)

        let error = await #expect(throws: PostingError.self) {
            _ = try await service.send(draft(thread: 1))
        }
        #expect(error?.code == .banned)
        #expect(error?.message.contains("Флуд") == true)
        #expect(error?.requiresNewCaptcha == false)
    }

    @Test("a closed thread is reported so the form can stop offering to reply")
    func mapsClosedThread() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/user/posting", data: try FixtureLoader.data(.postingErrorThreadClosed)
        )
        let service = makeService(transport)

        let error = await #expect(throws: PostingError.self) {
            _ = try await service.send(draft(thread: 1))
        }
        #expect(error?.code == .threadClosed)
    }
}

@Suite("Wakaba markup")
struct WakabaMarkupTests {
    @Test("wrapping applies the site's own syntax", arguments: [
        (WakabaMarkup.Style.bold, "**текст**"),
        (.italic, "*текст*"),
        (.underline, "__текст__"),
        (.strikethrough, "[s]текст[/s]"),
        (.overline, "[o]текст[/o]"),
        (.spoiler, "%%текст%%"),
        (.code, "[code]текст[/code]"),
        (.superscript, "[sup]текст[/sup]"),
        (.subscript, "[sub]текст[/sub]"),
    ])
    func wraps(style: WakabaMarkup.Style, expected: String) {
        #expect(WakabaMarkup.wrap("текст", in: style) == expected)
    }

    @Test("wrapping an empty selection leaves the cursor between the markers")
    func wrapsEmptySelection() {
        let result = WakabaMarkup.wrapping("", in: .bold)
        #expect(result.text == "****")
        #expect(result.cursorOffset == 2)
    }

    @Test("quoting a selection prefixes every line")
    func quotesEveryLine() {
        #expect(WakabaMarkup.quote("раз\nдва") == ">раз\n>два\n")
    }

    @Test("quoting skips lines that are already quoted")
    func doesNotDoubleQuote() {
        #expect(WakabaMarkup.quote(">раз\nдва") == ">раз\n>два\n")
    }

    @Test("a reply link is appended with a newline so typing continues below")
    func replyLink() {
        #expect(WakabaMarkup.replyLink(to: 123) == ">>123\n")
    }

    @Test("quoting a post writes the link and then the quoted text")
    func quotePost() {
        let result = WakabaMarkup.quotePost(num: 5, text: "привет\nмир")
        #expect(result.hasPrefix(">>5\n"))
        #expect(result.contains(">привет"))
        #expect(result.contains(">мир"))
    }
}
