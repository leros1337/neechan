import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// What the reader has already picked in the captcha.
///
/// The site replaces the whole keyboard on every tap and never says what has
/// been answered, so the app is the only place this can be kept.
@Suite("Captcha selection", .serialized)
@MainActor
struct CaptchaSelectionTests {
    private func makeModel() throws -> (ReplyFormViewModel, StubTransport) {
        let transport = StubTransport()
        let services = try AppServices.inMemory(
            settings: AppSettings(
                defaults: UserDefaults(suiteName: "captcha.\(UUID().uuidString)")!
            ),
            transport: transport
        )
        return (ReplyFormViewModel(board: "test", thread: 1, services: services), transport)
    }

    /// Stubs a captcha that asks for a symbol, then another, then accepts.
    private func stubCaptcha(_ transport: StubTransport) async throws {
        await transport.stub(
            pathContaining: "/api/captcha/emoji/id", data: try FixtureLoader.data(.captchaEmojiID)
        )
        await transport.stub(
            pathContaining: "/api/captcha/emoji/show", data: try FixtureLoader.data(.captchaEmojiShow)
        )
        await transport.stub(
            pathContaining: "/api/captcha/emoji/click",
            data: try FixtureLoader.data(.captchaEmojiClickStep)
        )
    }

    @Test("nothing is picked before the reader taps")
    func startsEmpty() async throws {
        let (model, transport) = try makeModel()
        try await stubCaptcha(transport)

        await model.loadCaptcha()
        #expect(model.chosenCaptchaKeys.isEmpty)
    }

    @Test("each tap is remembered, in the order it was made")
    func tapsAccumulate() async throws {
        let (model, transport) = try makeModel()
        try await stubCaptcha(transport)
        await model.loadCaptcha()

        await model.selectEmoji(at: 0)
        #expect(model.chosenCaptchaKeys.count == 1)

        await model.selectEmoji(at: 1)
        #expect(model.chosenCaptchaKeys.count == 2, "the next keyboard must not erase the first pick")
    }

    @Test("reloading the captcha starts the list over")
    func reloadClears() async throws {
        let (model, transport) = try makeModel()
        try await stubCaptcha(transport)
        await model.loadCaptcha()
        await model.selectEmoji(at: 0)
        #expect(model.chosenCaptchaKeys.isEmpty == false)

        await model.loadCaptcha()
        #expect(model.chosenCaptchaKeys.isEmpty)
    }

    @Test("solving it clears the list")
    func solvingClears() async throws {
        let (model, transport) = try makeModel()
        try await stubCaptcha(transport)
        await model.loadCaptcha()
        await model.selectEmoji(at: 0)

        // The next tap is answered with the solved token.
        await transport.stub(
            pathContaining: "/api/captcha/emoji/click",
            data: try FixtureLoader.data(.captchaEmojiClickSuccess)
        )
        await model.selectEmoji(at: 0)

        #expect(model.chosenCaptchaKeys.isEmpty)
    }

    /// A tap that arrives after the keyboard has gone must not crash.
    @Test("a tap past the end of the keyboard is ignored")
    func outOfRangeTapIsSafe() async throws {
        let (model, transport) = try makeModel()
        try await stubCaptcha(transport)
        await model.loadCaptcha()

        await model.selectEmoji(at: 999)
        #expect(model.chosenCaptchaKeys.isEmpty)
    }
}
