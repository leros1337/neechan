import Foundation
import Synchronization
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

/// Proving the captcha path works, without ever solving one.
///
/// The puzzle is the reader's to answer. These tests check that the app asks
/// the right host for it, hands the browser check over instead of grinding
/// against it, and can read a served puzzle into its two images — and nothing
/// beyond that. No offset is computed, no characters are guessed, nothing is
/// posted.
@Suite("4chan captcha")
struct FourchanCaptchaTests {
    private func client(_ transport: StubTransport) -> DvachClient {
        // No retries: the answer is a gate or a puzzle, and neither improves by
        // being asked for again.
        DvachClient(transport: transport, site: { .init(site: .fourchan) }, retryPolicy: .none)
    }

    @Test("a captcha is asked for on the posting host, with the board and thread")
    func requestGoesToTheRightPlace() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/captcha",
            data: try FixtureLoader.data(.fourchanCaptchaChallenge)
        )
        _ = try await client(transport).fourchanCaptcha(board: "po", thread: 1)

        let url = try #require(await transport.requestedURLs().first)
        #expect(url.hasPrefix("https://sys.4chan.org/captcha?"))
        #expect(url.contains("board=po"))
        #expect(url.contains("thread_id=1"))
    }

    @Test("a new thread asks for a captcha with no thread at all")
    func newThreadHasNoThreadID() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/captcha",
            data: try FixtureLoader.data(.fourchanCaptchaChallenge)
        )
        _ = try await client(transport).fourchanCaptcha(board: "po")

        let url = try #require(await transport.requestedURLs().first)
        #expect(url.contains("thread_id") == false)
    }

    /// The assertion that actually matters: the gate is handed to the reader
    /// after exactly one request. Retrying cannot pass a browser check, and a
    /// client that tried would earn itself a longer block.
    @Test("the browser check is handed to the reader instead of being retried")
    func challengeIsSurfacedNotRetried() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: try FixtureLoader.data(.fourchanCloudflareGate),
            statusCode: 403,
            headers: ["cf-mitigated": "challenge", "content-type": "text/html; charset=UTF-8"]
        )

        let reported = Mutex<[URL]>([])
        let client = DvachClient(
            transport: transport,
            site: { .init(site: .fourchan) },
            onChallenge: { url in reported.withLock { $0.append(url) } }
        )

        await #expect(throws: DvachError.self) {
            _ = try await client.fourchanCaptcha(board: "po")
        }
        do {
            _ = try await client.fourchanCaptcha(board: "po")
            Issue.record("the gate should not have been treated as an answer")
        } catch let error as DvachError {
            guard case .cloudflareChallenge(let url) = error else {
                Issue.record("expected a browser check, got \(error)")
                return
            }
            #expect(url.absoluteString.contains("sys.4chan.org/captcha"))
        }

        // One request per attempt, and no more: the retry loop is skipped.
        #expect(await transport.recordedRequests().count == 2)
        #expect(reported.withLock { $0 }.count == 2)
    }

    @Test("the check is recognised from its header, whatever the body says")
    func headerAloneIsEnough() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data(#"{"challenge":"looks-fine"}"#.utf8),
            statusCode: 403,
            headers: ["cf-mitigated": "challenge"]
        )
        await #expect(throws: DvachError.self) {
            _ = try await client(transport).fourchanCaptcha(board: "po")
        }
    }

    /// The gate detector was written for 2ch and carries a Russian marker among
    /// its others. 4chan's page has to be recognised by the generic ones.
    @Test("4chan's own gate page is recognised without 2ch's Russian marker")
    func gatePageIsRecognisedOnItsOwn() throws {
        let page = try FixtureLoader.data(.fourchanCloudflareGate)
        #expect(String(decoding: page, as: UTF8.self).contains("Проверка") == false)

        let reply = HTTPReply(
            data: page,
            statusCode: 403,
            headers: ["content-type": "text/html; charset=UTF-8"],
            url: URL(string: "https://sys.4chan.org/captcha?board=po")
        )
        #expect(ChallengeDetector.isChallenge(reply))
    }

    /// Reading a served puzzle: two images and a lifetime, and nothing else is
    /// done with them here or anywhere.
    @Test("a served captcha is read into its two images and its lifetime")
    func servedCaptchaIsReadable() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/captcha",
            data: try FixtureLoader.data(.fourchanCaptchaChallenge)
        )
        let captcha = try await client(transport).fourchanCaptcha(board: "po")

        #expect(captcha.challenge?.isEmpty == false)
        #expect(captcha.isSolvable)
        #expect(captcha.isNotRequired == false)
        #expect(captcha.ttl == 120)
        // Both strips decode as images. Nothing looks at what is in them.
        #expect(Data(base64Encoded: try #require(captcha.image)) != nil)
        #expect(Data(base64Encoded: try #require(captcha.background)) != nil)
    }

    @Test("a cooldown is reported as a rate limit, not mistaken for a puzzle")
    func cooldownIsARateLimit() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/captcha",
            data: try FixtureLoader.data(.fourchanCaptchaCooldown)
        )
        do {
            _ = try await client(transport).fourchanCaptcha(board: "po")
            Issue.record("a cooldown should not read as a captcha")
        } catch let error as DvachError {
            #expect(error.code == .rateLimited)
            #expect(error.serverMessage?.isEmpty == false)
        }
    }

    @Test("a pass holder is told no captcha is needed")
    func noopMeansNothingToSolve() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/captcha", data: Data(#"{"challenge":"noop"}"#.utf8))
        let captcha = try await client(transport).fourchanCaptcha(board: "po")

        #expect(captcha.isNotRequired)
        #expect(captcha.isSolvable == false)
    }

    @Test("2ch is not asked for a slider captcha it does not have")
    func dvachHasNoSliderCaptcha() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("{}".utf8))
        let client = DvachClient(transport: transport, site: { .init(site: .dvach) })

        await #expect(throws: DvachError.self) {
            _ = try await client.fourchanCaptcha(board: "b")
        }
        #expect(await transport.recordedRequests().isEmpty)
    }
}

/// What happens when a JSON endpoint answers with a page instead.
///
/// This is what a reader hits on the captcha: the gate refuses the request,
/// and until it was told apart from a malformed reply the app said only that it
/// could not read the answer — which is true and useless, because the thing to
/// do about it is answer the check.
@Suite("A page where JSON was expected")
struct UnreadableCaptchaAnswerTests {
    private func client(
        _ transport: StubTransport,
        onChallenge: (@Sendable (URL) -> Void)? = nil
    ) -> DvachClient {
        DvachClient(
            transport: transport,
            site: { .init(site: .fourchan) },
            retryPolicy: .none,
            onChallenge: onChallenge
        )
    }

    /// A gate can arrive with a 200 and its markers in the body, and it has to
    /// be spotted here as well as on the way out of the retry loop.
    @Test("a gate that answers 200 is still offered to the reader")
    func gateUnder200IsAChallenge() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: try FixtureLoader.data(.fourchanCloudflareGate),
            headers: ["content-type": "text/html"]
        )
        let reported = Mutex<[URL]>([])
        let client = client(transport) { url in reported.withLock { $0.append(url) } }

        do {
            _ = try await client.fourchanCaptcha(board: "po")
            Issue.record("a gate should not read as a captcha")
        } catch let error as DvachError {
            guard case .cloudflareChallenge = error else {
                Issue.record("expected a browser check, got \(error)")
                return
            }
        }
        #expect(reported.withLock { $0 }.count == 1)
    }

    /// The rule that stops an endless flicker: a page carrying no sign of a
    /// gate cannot be passed, so offering the reader a browser check for one
    /// puts them in a loop — answer the check, retry, get the same page, be
    /// shown the check again. It is reported as unreadable, which is what it
    /// is, and logged so it can be identified.
    @Test("a page that is not a gate is not offered as one")
    func plainPageIsNotAChallenge() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data("<!DOCTYPE html><html><body>Nothing to see</body></html>".utf8),
            headers: ["content-type": "text/html"]
        )
        let reported = Mutex<[URL]>([])
        let client = client(transport) { url in reported.withLock { $0.append(url) } }

        do {
            _ = try await client.fourchanCaptcha(board: "po")
            Issue.record("a page should not read as a captcha")
        } catch let error as DvachError {
            guard case .decoding = error else {
                Issue.record("expected an unreadable answer, got \(error)")
                return
            }
        }
        // And crucially, no check is raised for something a check cannot fix.
        #expect(reported.withLock { $0 }.isEmpty)
    }

    @Test("an answer that is neither a page nor a captcha is still reported plainly")
    func brokenJSONIsStillADecodingFailure() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("not json at all".utf8))
        do {
            _ = try await client(transport).fourchanCaptcha(board: "po")
            Issue.record("expected a failure")
        } catch let error as DvachError {
            guard case .decoding = error else {
                Issue.record("expected a decoding failure, got \(error)")
                return
            }
        }
    }

    @Test("a body's own shape gives it away when the label does not")
    func htmlIsRecognisedByItsFirstCharacter() {
        let page = HTTPReply(
            data: Data("\n  <html></html>".utf8),
            statusCode: 200,
            headers: ["content-type": "application/json"],
            url: nil
        )
        #expect(page.looksLikeHTML)

        let json = HTTPReply(
            data: Data(#"{"challenge":"x"}"#.utf8),
            statusCode: 200,
            headers: [:],
            url: nil
        )
        #expect(json.looksLikeHTML == false)
    }
}

@Suite("Reading an undocumented captcha")
struct FourchanCaptchaDecodingTests {
    private func captcha(_ json: String) throws -> FourchanCaptcha {
        try JSONDecoder().decode(FourchanCaptcha.self, from: Data(json.utf8))
    }

    @Test("the shape the site's own script expects")
    func canonical() throws {
        let read = try captcha(#"""
        {"challenge":"abc","img":"AAA","bg":"BBB","img_width":300,"bg_width":400,"ttl":120}
        """#)
        #expect(read.challenge == "abc")
        #expect(read.ttl == 120)
        #expect(read.backgroundWidth == 400)
        #expect(read.isSolvable)
    }

    /// Being strict here costs the reader the whole feature and tells them only
    /// that something was unreadable, so every number is taken as it comes.
    @Test("a number that arrives in another form is still read")
    func numbersAreTolerated() throws {
        #expect(try captcha(#"{"challenge":"a","img":"x","ttl":"120"}"#).ttl == 120)
        #expect(try captcha(#"{"challenge":"a","img":"x","ttl":119.6}"#).ttl == 120)
        #expect(try captcha(#"{"error":"slow down","cd":27.5}"#).cooldown == 28)
    }

    @Test("a field the site has stopped sending is simply absent")
    func missingFieldsAreFine() throws {
        let read = try captcha(#"{"challenge":"abc","img":"AAA"}"#)
        #expect(read.background == nil)
        #expect(read.ttl == nil)
        // Still answerable: the easier variant carries no sliding background.
        #expect(read.isSolvable)
    }

    @Test("a pass holder's answer is not mistaken for a puzzle")
    func noop() throws {
        let read = try captcha(#"{"challenge":"noop"}"#)
        #expect(read.isNotRequired)
        #expect(read.isSolvable == false)
    }

    @Test("an empty object is not a puzzle either")
    func empty() throws {
        #expect(try captcha("{}").isSolvable == false)
    }
}

/// 4chan's own gate, which is not Cloudflare's.
///
/// It answers a JSON endpoint with a page whose entire body is a script that
/// writes a `_tcs` cookie from the clock, the timezone and the length of
/// `eval`'s own source, then reloads. Nothing about it says Cloudflare, and it
/// carries no title, so it went unrecognised: the reader was told the answer
/// could not be read, and the cookie they had just earned in the web view was
/// thrown away because only `cf_clearance` was being collected.
@Suite("4chan's own interstitial")
struct FourchanInterstitialTests {
    /// The real body, as logged from a device.
    private let interstitial = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title></title>
    <script>document.cookie = `_tcs=${0|(Date.now()/1000)}.    ${new window.Intl.DateTimeFormat().resolvedOptions().timeZone}.1789654680.    ${window.eval.toString().length}..`;location.reload()</script></head></html>
    """

    private func reply(_ body: String, contentType: String = "text/html") -> HTTPReply {
        HTTPReply(
            data: Data(body.utf8),
            statusCode: 200,
            headers: ["content-type": contentType],
            url: URL(string: "https://sys.4chan.org/captcha?board=ck")
        )
    }

    @Test("the page that asks the browser to write a cookie is a gate")
    func interstitialIsRecognised() {
        #expect(ChallengeDetector.isChallenge(reply(interstitial)))
    }

    @Test("an ordinary page is still not a gate")
    func plainPageIsNot() {
        #expect(ChallengeDetector.isChallenge(reply("<html><body>hello</body></html>")) == false)
    }

    /// Collecting only Cloudflare's cookie is what made passing the check
    /// achieve nothing on this site.
    @Test("the cookie 4chan's gate issues is one the app collects")
    func gateCookieIsCollected() {
        #expect(Imageboard.fourchan.gateCookieNames.contains("_tcs"))
        #expect(Imageboard.fourchan.gateCookieNames.contains("cf_clearance"))
        // 2ch has no such script, and nothing should go looking for one.
        #expect(Imageboard.dvach.gateCookieNames == ["cf_clearance"])
    }

    @Test("a reader who has passed it is offered the check, not an error")
    func readerIsOfferedTheCheck() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data(interstitial.utf8),
            headers: ["content-type": "text/html"]
        )
        let reported = Mutex<[URL]>([])
        let client = DvachClient(
            transport: transport,
            site: { .init(site: .fourchan) },
            retryPolicy: .none,
            onChallenge: { url in reported.withLock { $0.append(url) } }
        )

        await #expect(throws: DvachError.self) {
            _ = try await client.fourchanCaptcha(board: "ck")
        }
        #expect(reported.withLock { $0 }.count == 1)
    }
}
