import Foundation
import Synchronization
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

/// A gate in front of one of 4chan's JSON hosts.
///
/// The captcha no longer goes through here — it is loaded in a browser frame,
/// which meets these gates itself — but the client still has to recognise one
/// on any request and hand it to the reader rather than grind against it. The
/// board's thread list stands in for any JSON request.
@Suite("4chan's gates")
struct FourchanGateTests {
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

        do {
            _ = try await client.boardThreadCounts(board: "po")
            Issue.record("the gate should not have been treated as an answer")
        } catch {
            guard case .cloudflareChallenge(let url) = error else {
                Issue.record("expected a browser check, got \(error)")
                return
            }
            #expect(url.absoluteString.contains("a.4cdn.org/po/threads.json"))
        }

        // One request, and no more: the retry loop is skipped.
        #expect(await transport.recordedRequests().count == 1)
        #expect(reported.withLock { $0 }.count == 1)
    }

    @Test("the check is recognised from its header, whatever the body says")
    func headerAloneIsEnough() async throws {
        let transport = StubTransport()
        await transport.stubEverything(
            data: Data("{}".utf8),
            statusCode: 403,
            headers: ["cf-mitigated": "challenge"]
        )
        let client = DvachClient(transport: transport, site: { .init(site: .fourchan) }, retryPolicy: .none)
        await #expect(throws: DvachError.self) {
            _ = try await client.boardThreadCounts(board: "po")
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
}

/// What happens when a JSON endpoint answers with a page instead.
///
/// This is what a reader used to hit on the captcha: the gate refuses the
/// request, and until it was told apart from a malformed reply the app said only that it
/// could not read the answer — which is true and useless, because the thing to
/// do about it is answer the check.
@Suite("A page where JSON was expected")
struct UnreadableAnswerTests {
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
            _ = try await client.boardThreadCounts(board: "po")
            Issue.record("a gate should not read as an answer")
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
            _ = try await client.boardThreadCounts(board: "po")
            Issue.record("a page should not read as an answer")
        } catch let error as DvachError {
            guard case .decoding = error else {
                Issue.record("expected an unreadable answer, got \(error)")
                return
            }
        }
        // And crucially, no check is raised for something a check cannot fix.
        #expect(reported.withLock { $0 }.isEmpty)
    }

    @Test("an answer that is neither a page nor JSON is still reported plainly")
    func brokenJSONIsStillADecodingFailure() async throws {
        let transport = StubTransport()
        await transport.stubEverything(data: Data("not json at all".utf8))
        do {
            _ = try await client(transport).boardThreadCounts(board: "po")
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
            _ = try await client.boardThreadCounts(board: "ck")
        }
        #expect(reported.withLock { $0 }.count == 1)
    }
}
