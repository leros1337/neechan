import Foundation
import NeechanAPITesting
import NeechanTestSupport
import Testing
@testable import NeechanAPI

/// The recorded challenge, with the answer the recorder solved for it.
private struct RecordedPoW: Decodable {
    struct Challenge: Decodable {
        let hash: String
        let limit: Int
        let template: String
    }
    let challenge: Challenge
    let expectedAnswer: Int?
}

@Suite("Proof of work")
struct ProofOfWorkTests {
    @Test("the recorded challenge is solved to the number the site expects")
    func solvesRecordedChallenge() async throws {
        let recorded = try FixtureLoader.decode(RecordedPoW.self, from: .powCase)
        let expected = try #require(recorded.expectedAnswer)

        let challenge = CaptchaChallenge(
            hash: recorded.challenge.hash,
            limit: recorded.challenge.limit,
            template: recorded.challenge.template
        )
        #expect(await ProofOfWork.solve(challenge) == expected)
    }

    @Test("a challenge whose answer is outside the limit yields nothing")
    func givesUpAtTheLimit() async throws {
        let recorded = try FixtureLoader.decode(RecordedPoW.self, from: .powCase)
        let answer = try #require(recorded.expectedAnswer)
        try #require(answer > 0, "the recorded answer must be positive for this test to mean anything")

        let challenge = CaptchaChallenge(
            hash: recorded.challenge.hash,
            limit: answer,  // exclusive, so the real answer is just out of reach
            template: recorded.challenge.template
        )
        #expect(await ProofOfWork.solve(challenge) == nil)
    }

    @Test("a template with no placeholder cannot be solved")
    func rejectsTemplateWithoutPlaceholder() async {
        let challenge = CaptchaChallenge(hash: String(repeating: "0", count: 128), limit: 10, template: "no placeholder")
        #expect(await ProofOfWork.solve(challenge) == nil)
    }

    @Test("a zero limit is refused rather than looping")
    func rejectsZeroLimit() async {
        let challenge = CaptchaChallenge(hash: "abc", limit: 0, template: "x%d")
        #expect(await ProofOfWork.solve(challenge) == nil)
    }

    @Test("an absurd limit is capped, so a hostile challenge cannot hang the app")
    func capsTheSearch() async {
        let challenge = CaptchaChallenge(
            hash: String(repeating: "f", count: 128),
            limit: Int.max,
            template: "x%d"
        )
        // Unsolvable, but it must still return rather than run forever.
        #expect(await ProofOfWork.solve(challenge) == nil)
    }

    @Test("solving can be cancelled")
    func honoursCancellation() async throws {
        let challenge = CaptchaChallenge(
            hash: String(repeating: "f", count: 128),
            limit: ProofOfWork.searchCeiling,
            template: "x%d"
        )
        let task = Task { await ProofOfWork.solve(challenge) }
        task.cancel()
        #expect(await task.value == nil)
    }
}

@Suite("Emoji captcha")
struct EmojiCaptchaTests {
    private func makeSession(_ transport: StubTransport) -> EmojiCaptchaSession {
        EmojiCaptchaSession(
            client: DvachClient(transport: transport, domain: { .org })
        )
    }

    @Test("starting a captcha returns the keyboard and keeps the challenge")
    func startsCaptcha() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/api/captcha/emoji/id", data: try FixtureLoader.data(.captchaEmojiID))
        await transport.stub(pathSuffix: "/api/captcha/emoji/show", data: try FixtureLoader.data(.captchaEmojiShow))

        let session = makeSession(transport)
        let state = try await session.start(board: "test", thread: nil)

        guard case .challenge(let step) = state else {
            Issue.record("expected a challenge, got \(state)")
            return
        }
        #expect(step.keyboard.isEmpty == false)
        #expect(step.image.isEmpty == false)
        #expect(await session.proofOfWorkChallenge != nil)
    }

    @Test("a passcode holder is told no captcha is needed")
    func passcodeSkipsCaptcha() async throws {
        let transport = StubTransport()
        await transport.stub(
            pathSuffix: "/api/captcha/emoji/id",
            data: try FixtureLoader.data(.captchaEmojiIDPasscode)
        )

        let state = try await makeSession(transport).start(board: "test", thread: nil)
        guard case .notRequired(let reason) = state else {
            Issue.record("expected the captcha to be skipped, got \(state)")
            return
        }
        #expect(reason == .passcode)
    }

    @Test("tapping an emoji that does not finish the captcha returns the next step")
    func clickReturnsNextStep() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/api/captcha/emoji/id", data: try FixtureLoader.data(.captchaEmojiID))
        await transport.stub(pathSuffix: "/api/captcha/emoji/show", data: try FixtureLoader.data(.captchaEmojiShow))
        await transport.stub(
            pathSuffix: "/api/captcha/emoji/click",
            data: try FixtureLoader.data(.captchaEmojiClickStep)
        )

        let session = makeSession(transport)
        _ = try await session.start(board: "test", thread: nil)
        let state = try await session.select(emojiAt: 0)

        guard case .challenge(let step) = state else {
            Issue.record("expected another step, got \(state)")
            return
        }
        #expect(step.keyboard.count == 3)
    }

    @Test("solving the captcha yields the token the post must carry")
    func clickCanSolve() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/api/captcha/emoji/id", data: try FixtureLoader.data(.captchaEmojiID))
        await transport.stub(pathSuffix: "/api/captcha/emoji/show", data: try FixtureLoader.data(.captchaEmojiShow))
        await transport.stub(
            pathSuffix: "/api/captcha/emoji/click",
            data: try FixtureLoader.data(.captchaEmojiClickSuccess)
        )

        let session = makeSession(transport)
        _ = try await session.start(board: "test", thread: nil)
        let state = try await session.select(emojiAt: 2)

        guard case .solved(let token) = state else {
            Issue.record("expected a solved captcha, got \(state)")
            return
        }
        #expect(token.isEmpty == false)
    }

    @Test("the click request carries the token and the zero-based emoji index")
    func clickRequestShape() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/api/captcha/emoji/id", data: try FixtureLoader.data(.captchaEmojiID))
        await transport.stub(pathSuffix: "/api/captcha/emoji/show", data: try FixtureLoader.data(.captchaEmojiShow))
        await transport.stub(
            pathSuffix: "/api/captcha/emoji/click",
            data: try FixtureLoader.data(.captchaEmojiClickSuccess)
        )

        let session = makeSession(transport)
        _ = try await session.start(board: "test", thread: nil)
        _ = try await session.select(emojiAt: 4)

        let request = try #require(await transport.lastRequest())
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["emojiNumber"] as? Int == 4)
        #expect((json["captchaTokenID"] as? String)?.isEmpty == false)
    }

    @Test("selecting before starting is refused rather than sending a bad request")
    func selectBeforeStart() async {
        let session = makeSession(StubTransport())
        await #expect(throws: (any Error).self) {
            _ = try await session.select(emojiAt: 0)
        }
    }

    @Test("the id request names the board and thread the post is for")
    func idRequestCarriesContext() async throws {
        let transport = StubTransport()
        await transport.stub(pathSuffix: "/api/captcha/emoji/id", data: try FixtureLoader.data(.captchaEmojiID))
        await transport.stub(pathSuffix: "/api/captcha/emoji/show", data: try FixtureLoader.data(.captchaEmojiShow))

        _ = try await makeSession(transport).start(board: "test", thread: 42)
        let urls = await transport.requestedURLs()
        let idURL = try #require(urls.first { $0.contains("/emoji/id") })
        #expect(idURL.contains("board=test"))
        #expect(idURL.contains("thread=42"))
    }
}
