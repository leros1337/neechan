import Foundation
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

/// The agent every request presents.
///
/// Serialized because it is one value for the whole app, which is the point of
/// it: two tests changing it at once would be testing each other.
@Suite("User agent", .serialized)
struct UserAgentTests {
    private func makeClient(_ transport: StubTransport) -> DvachClient {
        DvachClient(transport: transport, domain: { .org })
    }

    @Test("before anything is read, a plausible browser agent is sent")
    func fallbackIsABrowser() {
        UserAgent.reset()

        #expect(UserAgent.current == UserAgent.fallback)
        #expect(UserAgent.current.contains("Mozilla/5.0"))
        #expect(UserAgent.current.contains("iPhone"))
    }

    @Test("the device's own agent replaces it")
    func setReplaces() {
        UserAgent.reset()
        defer { UserAgent.reset() }

        UserAgent.set("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15")
        #expect(UserAgent.current.contains("27_0"))
    }

    /// An empty header is worse than a stale one, and a web view that fails to
    /// answer hands back an empty string.
    @Test("a blank agent is ignored", arguments: ["", "   ", "\n"])
    func blankIsIgnored(agent: String) {
        UserAgent.reset()
        UserAgent.set(agent)

        #expect(UserAgent.current == UserAgent.fallback)
    }

    @Test("surrounding whitespace is trimmed")
    func trims() {
        UserAgent.reset()
        defer { UserAgent.reset() }

        UserAgent.set("  Mozilla/5.0 (iPhone)\n")
        #expect(UserAgent.current == "Mozilla/5.0 (iPhone)")
    }

    /// The agent is read from a web view after the transport already exists, so
    /// a transport that captured it at build time would send the fallback for
    /// the rest of the session.
    @Test("a transport built before the agent arrives still sends the new one")
    func transportPicksUpALaterAgent() throws {
        UserAgent.reset()
        defer { UserAgent.reset() }

        let transport = URLSessionTransport(session: .shared)
        UserAgent.set("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) TestAgent/1")

        let sent = transport.identifying(
            URLRequest(url: try #require(URL(string: "https://2ch.org/b/catalog.json")))
        )
        #expect(sent.value(forHTTPHeaderField: "User-Agent")?.contains("TestAgent/1") == true)
    }

    @Test("a request that already names an agent keeps its own")
    func explicitAgentWins() throws {
        UserAgent.reset()
        let transport = URLSessionTransport(session: .shared)

        var request = URLRequest(url: try #require(URL(string: "https://2ch.org/b/catalog.json")))
        request.setValue("Something/1", forHTTPHeaderField: "User-Agent")

        #expect(
            transport.identifying(request).value(forHTTPHeaderField: "User-Agent") == "Something/1"
        )
    }
}
