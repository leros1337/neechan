import Foundation
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

@Suite("Dvach client")
struct ClientTests {
    /// A client whose retry backoff does not actually sleep.
    private func makeClient(
        _ transport: StubTransport,
        domain: DvachDomain = .org
    ) -> DvachClient {
        DvachClient(
            transport: transport,
            domain: { domain }
        )
    }

    // MARK: Requests

    @Test("reads carry a JSON Accept header")
    func acceptsJSON() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))
        _ = try await makeClient(transport).boards()

        let request = try #require(await transport.lastRequest())
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("the client follows the mirror it is given")
    func usesConfiguredDomain() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))
        _ = try await makeClient(transport, domain: .life).boards()

        let urls = await transport.requestedURLs()
        #expect(urls.first?.hasPrefix("https://2ch.life/") == true)
    }

    // MARK: Decoding

    @Test("the board list is returned decoded")
    func decodesBoards() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))
        let boards = try await makeClient(transport).boards()
        #expect(boards.contains { $0.id == "b" })
    }

    @Test("a thread is returned decoded")
    func decodesThread() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/res/1.json", data: try FixtureLoader.data(.thread))
        let thread = try await makeClient(transport).thread(board: "po", num: 1)
        #expect(thread.posts.isEmpty == false)
    }

    @Test("a body that is not the expected JSON surfaces a decoding error")
    func reportsDecodingFailure() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: Data(#"{"unexpected":true}"#.utf8))

        await #expect(throws: DvachError.self) {
            _ = try await makeClient(transport).boards()
        }
    }

    // MARK: Error envelopes

    @Test("an error envelope becomes a typed API error")
    func mapsErrorEnvelope() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/api/mobile/v2/after/b/1/0",
            data: try FixtureLoader.data(.errorNoPost)
        )
        let client = makeClient(transport)

        let error = await #expect(throws: DvachError.self) {
            _ = try await client.after(board: "b", thread: 1, sinceNum: 0)
        }
        #expect(error?.code == .noPost)
        #expect(error?.serverMessage?.isEmpty == false)
    }

    @Test("a successful envelope is not treated as an error")
    func successEnvelopePasses() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/info/po/1", data: try FixtureLoader.data(.threadInfo))
        let info = try await makeClient(transport).threadInfo(board: "po", thread: 1)
        #expect(info.thread?.posts ?? 0 > 0)
    }

    // MARK: HTTP failures

    @Test("a 404 is reported with its status")
    func mapsNotFound() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/res/1.json", data: Data(), statusCode: 404)
        let client = makeClient(transport)

        let error = await #expect(throws: DvachError.self) {
            _ = try await client.thread(board: "b", num: 1)
        }
        guard case .http(let status, _) = try #require(error) else {
            Issue.record("expected an http error, got \(String(describing: error))")
            return
        }
        #expect(status == 404)
    }

    @Test("a transport failure is wrapped, not swallowed")
    func wrapsTransportFailure() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", failingWith: URLError(.notConnectedToInternet))
        let client = makeClient(transport)

        let error = await #expect(throws: DvachError.self) { _ = try await client.boards() }
        guard case .transport = try #require(error) else {
            Issue.record("expected a transport error")
            return
        }
    }

    // MARK: Retry

    @Test("a 503 is retried, and the retry's answer is used")
    func retriesServerErrors() async throws {
        let transport = StubTransport()
        // Registered first, so it is the fallback once the 503 stub is consumed.
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))
        await transport.stubOnce(pathSuffix: "/boards", data: Data(), statusCode: 503)

        let boards = try await makeClient(transport).boards()
        #expect(boards.isEmpty == false)
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test("retries stop at the configured limit")
    func retriesAreBounded() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: Data(), statusCode: 503)
        let client = makeClient(transport)

        await #expect(throws: DvachError.self) { _ = try await client.boards() }
        // One initial attempt plus the policy's retries.
        #expect(await transport.recordedRequests().count == RetryPolicy.default.backoff.count)
    }

    @Test("a 404 is not retried")
    func clientErrorsAreNotRetried() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: Data(), statusCode: 404)
        let client = makeClient(transport)

        await #expect(throws: DvachError.self) { _ = try await client.boards() }
        #expect(await transport.recordedRequests().count == 1)
    }

    // MARK: Firewall

    @Test("a challenge page is reported so the app can open a web view")
    func detectsChallenge() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/boards",
            data: try FixtureLoader.data(.cloudflareChallenge),
            statusCode: 403,
            headers: ["content-type": "text/html; charset=utf-8"]
        )
        let client = makeClient(transport)

        let error = await #expect(throws: DvachError.self) { _ = try await client.boards() }
        guard case .cloudflareChallenge(let url) = try #require(error) else {
            Issue.record("expected a challenge error, got \(String(describing: error))")
            return
        }
        #expect(url.absoluteString.contains("2ch.org"))
    }

    @Test("a challenge is not retried as if it were a server hiccup")
    func challengeIsNotRetried() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/boards",
            data: try FixtureLoader.data(.cloudflareChallenge),
            statusCode: 503,
            headers: ["content-type": "text/html; charset=utf-8"]
        )
        let client = makeClient(transport)

        await #expect(throws: DvachError.self) { _ = try await client.boards() }
        #expect(await transport.recordedRequests().count == 1)
    }
}

@Suite("Challenge detection")
struct ChallengeDetectorTests {
    private func reply(
        _ body: Data,
        status: Int = 200,
        contentType: String = "application/json"
    ) -> HTTPReply {
        HTTPReply(
            data: body,
            statusCode: status,
            headers: ["content-type": contentType],
            url: URL(string: "https://2ch.org/b/catalog.json")
        )
    }

    @Test("the recorded challenge page is recognised")
    func recognisesChallengePage() throws {
        let html = try FixtureLoader.data(.cloudflareChallenge)
        #expect(ChallengeDetector.isChallenge(reply(html, status: 403, contentType: "text/html")))
    }

    @Test("Cloudflare's own marker header is enough")
    func recognisesMitigatedHeader() {
        let reply = HTTPReply(
            data: Data(),
            statusCode: 403,
            headers: ["cf-mitigated": "challenge"],
            url: URL(string: "https://2ch.org/")
        )
        #expect(ChallengeDetector.isChallenge(reply))
    }

    @Test("HTML where JSON was expected is treated as a gate")
    func htmlInsteadOfJSONIsSuspicious() {
        let html = Data("<html><head><title>Проверка...</title></head><body></body></html>".utf8)
        #expect(ChallengeDetector.isChallenge(reply(html, status: 200, contentType: "text/html")))
    }

    @Test("a normal JSON body is not a challenge")
    func jsonIsNotAChallenge() throws {
        #expect(ChallengeDetector.isChallenge(reply(try FixtureLoader.data(.boards))) == false)
    }

    @Test("a JSON error envelope is not mistaken for a challenge")
    func errorEnvelopeIsNotAChallenge() throws {
        #expect(ChallengeDetector.isChallenge(reply(try FixtureLoader.data(.errorNoPost))) == false)
    }
}

@Suite("Domain holder")
struct DomainHolderTests {
    @Test("the domain can be read from an actor other than the main one")
    func readableOffTheMainActor() async {
        // This is the crash that shipped once: the client reads the domain from
        // its own executor, so a provider that assumes main-actor isolation
        // traps on the first request.
        let holder = DomainHolder(.org)

        actor Reader {
            func read(_ holder: DomainHolder) -> DvachDomain { holder.value }
        }
        #expect(await Reader().read(holder) == .org)
    }

    @Test("a change is visible to later reads")
    func updatesAreVisible() {
        let holder = DomainHolder(.org)
        holder.set(.life)
        #expect(holder.value == .life)
        #expect(holder.provider() == .life)
    }

    @Test("the client follows the holder without being rebuilt")
    func clientFollowsHolder() async throws {
        let holder = DomainHolder(.org)
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))

        let client = DvachClient(transport: transport, domain: holder.provider)
        _ = try await client.boards()
        holder.set(.life)
        _ = try await client.boards()

        let urls = await transport.requestedURLs()
        #expect(urls.first?.contains("2ch.org") == true)
        #expect(urls.last?.contains("2ch.life") == true)
    }
}

/// A request that cannot reach the network at all.
///
/// This path used to crash rather than throw: the retry loop left its `catch`
/// with `continue` after an `await`, which corrupts the task allocator, so the
/// app died whenever the connection dropped.
@Suite("Transport failures")
struct TransportFailureTests {
    private struct Boom: Error {}

    private func makeClient(_ transport: StubTransport) -> DvachClient {
        DvachClient(transport: transport, domain: { .org })
    }

    @Test("a transport that always fails is reported, not crashed on")
    func alwaysFailing() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", failingWith: Boom())

        await #expect(throws: DvachError.self) {
            try await makeClient(transport).boards()
        }
    }

    @Test("a failure followed by a success returns the success")
    func retryAfterFailure() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", data: try FixtureLoader.data(.boards))
        await transport.stubOnce(pathSuffix: "/boards", failingWith: Boom())

        let boards = try await makeClient(transport).boards()
        #expect(boards.isEmpty == false)
        #expect(await transport.recordedRequests().count > 1, "it should have tried again")
    }

    @Test("every retry is actually attempted before giving up")
    func exhaustsRetries() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", failingWith: Boom())

        _ = try? await makeClient(transport).boards()
        #expect(await transport.recordedRequests().count >= 2)
    }

    @Test("a thread refresh survives the network going away")
    func afterEndpointFailure() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/1/2", failingWith: Boom())

        await #expect(throws: DvachError.self) {
            try await makeClient(transport).after(board: "b", thread: 1, sinceNum: 2)
        }
    }
}

/// The same failure with the real backoff in place.
///
/// The crash needed the retry loop to actually suspend between attempts, which
/// the other tests skip by passing a sleep that returns at once.
@Suite("Transport failures with real backoff")
struct BackoffFailureTests {
    private struct Boom: Error {}

    @Test("a failing request with real delays throws instead of crashing")
    func failsWithRealSleep() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/boards", failingWith: Boom())
        let client = DvachClient(
            transport: transport,
            domain: { .org },
            retryPolicy: RetryPolicy(backoff: [.zero, .milliseconds(1)])
        )

        await #expect(throws: DvachError.self) {
            try await client.boards()
        }
    }

    @Test("a request with no stub at all is reported the same way")
    func unmatchedRequest() async throws {
        let client = DvachClient(
            transport: StubTransport(),
            domain: { .org },
            retryPolicy: RetryPolicy(backoff: [.zero, .milliseconds(1)])
        )

        await #expect(throws: DvachError.self) {
            try await client.after(board: "b", thread: 1, sinceNum: 2)
        }
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {
    private let policy = RetryPolicy(
        backoff: [.zero, .milliseconds(250), .milliseconds(500)],
        jitter: .milliseconds(200),
        retryAfterCap: .seconds(10)
    )

    @Test("the first attempt never waits")
    func firstAttemptIsImmediate() {
        #expect(policy.delay(beforeAttempt: 0, random: 0.5) == .zero)
    }

    @Test("there is no delay past the last attempt, which is how it gives up")
    func pastTheEnd() {
        #expect(policy.delay(beforeAttempt: 3, random: 0) == nil)
    }

    /// Without a spread every device that hit the same outage comes back at the
    /// same four moments.
    @Test("the spread stays inside the jitter it was given")
    func jitterIsBounded() {
        let lowest = policy.delay(beforeAttempt: 1, random: 0)
        let highest = policy.delay(beforeAttempt: 1, random: 1)

        #expect(lowest == .milliseconds(250))
        #expect(highest == .milliseconds(450))
    }

    @Test("what the server asked for wins over the schedule")
    func retryAfterIsHonoured() {
        #expect(policy.delay(beforeAttempt: 1, retryAfter: 3, random: 0) == .seconds(3))
    }

    @Test("a wait longer than the ceiling is given up on instead")
    func longRetryAfterGivesUp() {
        #expect(policy.delay(beforeAttempt: 1, retryAfter: 120, random: 0) == nil)
    }

    @Test("the polling policy makes one attempt and no more")
    func pollPolicyIsSingleShot() {
        #expect(RetryPolicy.poll.maxAttempts == 1)
        #expect(RetryPolicy.poll.delay(beforeAttempt: 1, random: 0) == nil)
    }
}

@Suite("Retrying against a server")
struct RetryBehaviourTests {
    private func makeClient(_ transport: StubTransport) -> DvachClient {
        DvachClient(
            transport: transport,
            domain: { .org },
            retryPolicy: RetryPolicy(backoff: [.zero, .zero, .zero])
        )
    }

    /// Answering "slow down" with three more requests is how a client gets
    /// itself blocked.
    @Test("being told to slow down is not answered with more requests")
    func rateLimitIsNotRetried() async throws {
        let transport = StubTransport()
        await transport.stub(pathContaining: "/catalog", data: Data(), statusCode: 429)
        let client = makeClient(transport)

        await #expect(throws: DvachError.self) {
            _ = try await client.catalog(board: "b")
        }
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test("a server error is still retried")
    func serverErrorsAreRetried() async throws {
        let transport = StubTransport()
        await transport.stub(pathContaining: "/catalog", data: Data(), statusCode: 503)
        let client = makeClient(transport)

        await #expect(throws: DvachError.self) {
            _ = try await client.catalog(board: "b")
        }
        #expect(await transport.recordedRequests().count == 3)
    }

    /// The watcher runs on a timer, so a failed poll is better left to the next
    /// pass than retried into a site that is already struggling.
    @Test("a watcher poll makes one attempt whatever the client's policy")
    func pollsAreNotRetried() async throws {
        let transport = StubTransport()
        await transport.stub(pathContaining: "/info/", data: Data(), statusCode: 503)
        let client = makeClient(transport)

        await #expect(throws: DvachError.self) {
            _ = try await client.threadInfo(board: "b", thread: 1)
        }
        #expect(await transport.recordedRequests().count == 1)
    }
}
