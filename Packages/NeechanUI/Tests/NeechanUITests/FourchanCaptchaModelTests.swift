import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// 4chan's captcha in the reply form, driven by a stand-in browser and a clock
/// the test owns.
///
/// Every wait here is the server's: the numbers come from the replies queued
/// below, and the model is only ever asked whether that much time has passed.
/// No step is ever answered by anything but the test playing the reader.
@Suite("4chan captcha in the reply form", .serialized)
@MainActor
struct FourchanCaptchaModelTests {
    @MainActor
    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    private struct Harness {
        let model: FourchanCaptchaModel
        let browser: FakeFourchanBrowser
        let clock: Clock
        let services: AppServices
    }

    private func makeHarness(thread: Int? = 1, installsBrowser: Bool = true) throws -> Harness {
        let settings = AppSettings(
            defaults: try #require(UserDefaults(suiteName: "fourchan-captcha.\(UUID().uuidString)"))
        )
        settings.imageboard = .fourchan
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        let browser = FakeFourchanBrowser()
        if installsBrowser { services.fourchanBrowser.install(browser) }
        let clock = Clock()
        let model = FourchanCaptchaModel(board: "po", thread: thread, services: services) { clock.now }
        return Harness(model: model, browser: browser, clock: clock, services: services)
    }

    private func sibling(of harness: Harness, thread: Int? = 1) -> FourchanCaptchaModel {
        FourchanCaptchaModel(board: "po", thread: thread, services: harness.services) { harness.clock.now }
    }

    private func puzzle(cooldown: Int = 30, ttl: Int = 120) -> String {
        #"""
        {"challenge":"c1","ttl":\#(ttl),"cd":\#(cooldown),
         "tasks":[{"str":"one","items":["A","B","C"]},{"img":"P","items":["D","E","F"]}]}
        """#
    }

    private func progress(_ model: FourchanCaptchaModel) -> FourchanCaptchaProgress? {
        if case .steps(let progress) = model.phase { return progress }
        return nil
    }

    // MARK: Asking

    /// Each request starts the site's cooldown, so it is the reader's to make.
    @Test("opening the form asks for nothing")
    func openingLoadsNothing() async throws {
        let harness = try makeHarness()
        harness.model.prepare()

        #expect(harness.model.phase == .idle)
        #expect(harness.model.canRequest)
        #expect(await harness.browser.loads.isEmpty)
    }

    @Test("the request names the board, the thread and the stored ticket, and keeps the new one")
    func requestCarriesTheTicket() async throws {
        let harness = try makeHarness()
        harness.services.settings.fourchanCaptchaTicket = "t0"
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterTasksSmall)))

        await harness.model.requestCaptcha()

        let frame = try #require(await harness.browser.loads.first?.frame.absoluteString)
        #expect(frame.contains("board=po"))
        #expect(frame.contains("thread_id=1"))
        #expect(frame.contains("ticket=t0"))
        #expect(harness.services.settings.fourchanCaptchaTicket == "synthetic-ticket")
    }

    @Test("a ticket the site withdraws is forgotten")
    func ticketIsDiscarded() async throws {
        let harness = try makeHarness()
        harness.services.settings.fourchanCaptchaTicket = "old"
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterTicketRevoked)))

        await harness.model.requestCaptcha()

        #expect(harness.services.settings.fourchanCaptchaTicket == nil)
    }

    // MARK: Waiting

    /// The cooldown has been 30, 60 and 300 seconds, and the button has to
    /// hold for exactly what the site said each time.
    @Test("Get Captcha stays off for exactly the cooldown the site sent", arguments: [30, 60, 300])
    func cooldownIsTheServers(seconds: Int) async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle(cooldown: seconds, ttl: 600))

        await harness.model.requestCaptcha()
        #expect(harness.model.canRequest == false)
        #expect(harness.model.secondsUntilRequest == seconds)

        harness.clock.advance(TimeInterval(seconds - 1))
        harness.model.tick()
        #expect(harness.model.canRequest == false)
        #expect(harness.model.secondsUntilRequest == 1)

        harness.clock.advance(1)
        harness.model.tick()
        #expect(harness.model.canRequest)
        #expect(harness.model.secondsUntilRequest == nil)
    }

    @Test("asking during the cooldown does nothing")
    func cooldownHoldsTheButton() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle())
        await harness.model.requestCaptcha()

        await harness.model.requestCaptcha()

        #expect(await harness.browser.loads.count == 1)
    }

    @Test("a refusal shows the site's words and still starts its cooldown")
    func refusal() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterRefused)))

        await harness.model.requestCaptcha()

        #expect(harness.model.phase == .refused("You have to wait a while before doing this again."))
        #expect(harness.model.secondsUntilRequest == 300)
        #expect(harness.model.answer == nil)
    }

    /// The longer wait replaces the shorter one, as on the site, and says why.
    @Test("a longer wait holds the button, with the site's message, then says so when it ends")
    func ticketWait() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterTicketWait)))

        await harness.model.requestCaptcha()

        #expect(harness.model.phase == .idle)
        #expect(harness.model.notice == "Please wait a while before requesting a captcha.")
        #expect(harness.model.secondsUntilRequest == 95)

        harness.clock.advance(95)
        harness.model.tick()
        #expect(harness.model.canRequest)
        #expect(harness.model.notice == "You can now request a captcha.")
    }

    @Test("a longer wait with no words of its own still explains itself")
    func ticketWaitDefaultMessage() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: #"{"pcd":60}"#)

        await harness.model.requestCaptcha()

        #expect(harness.model.notice == "Please wait a while.")
        #expect(harness.model.secondsUntilRequest == 60)
    }

    // MARK: Answering

    @Test("the slider starts on the instructions, and Next waits for the reader")
    func nothingIsChosenForTheReader() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle())
        await harness.model.requestCaptcha()

        let start = try #require(progress(harness.model))
        #expect(start.selection == 0)
        #expect(start.index == 0)

        harness.model.next()
        #expect(progress(harness.model) == start)
        #expect(harness.model.answer == nil)
    }

    @Test("the answer is the positions the reader picked, sent with the challenge")
    func answerIsTheReadersPicks() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle())
        await harness.model.requestCaptcha()

        harness.model.select(2)
        harness.model.next()
        #expect(progress(harness.model)?.selection == 0, "each step starts on its instructions")
        harness.model.select(3)
        harness.model.next()

        #expect(harness.model.phase == .answered)
        let answer = try #require(harness.model.answer)
        #expect(answer.challenge == "c1")
        #expect(answer.response == "12")
    }

    @Test("a challenge with nothing to answer is sent back with an empty answer")
    func notRequired() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterNoop)))

        await harness.model.requestCaptcha()

        #expect(harness.model.phase == .notRequired)
        #expect(harness.model.answer?.challenge == "noop")
        #expect(harness.model.answer?.response == "")
    }

    /// Three seconds early, as the site's own script expires it, and without
    /// asking for another: that would start a cooldown nobody asked for.
    @Test("a captcha expires three seconds before its lifetime, and no new one is asked for")
    func expiry() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle(ttl: 120))
        await harness.model.requestCaptcha()
        #expect(harness.model.secondsUntilExpiry == 117)

        harness.clock.advance(116)
        harness.model.tick()
        #expect(progress(harness.model) != nil)

        harness.clock.advance(1)
        harness.model.tick()
        #expect(harness.model.phase == .expired)
        #expect(harness.model.answer == nil)
        #expect(await harness.browser.loads.count == 1)
    }

    @Test("an answered captcha expires too")
    func answeredExpires() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterNoop)))
        await harness.model.requestCaptcha()

        harness.clock.advance(117)
        harness.model.tick()

        #expect(harness.model.answer == nil)
    }

    // MARK: After sending

    @Test("a sent captcha is spent, without asking for another")
    func consume() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterNoop)))
        await harness.model.requestCaptcha()

        harness.model.consume()

        #expect(harness.model.phase == .idle)
        #expect(harness.model.answer == nil)
        #expect(harness.model.secondsUntilRequest == 30, "the site's cooldown still stands")
        #expect(await harness.browser.loads.count == 1)
    }

    // MARK: Closing and reopening

    @Test("closing the form keeps the cooldown and the unfinished puzzle")
    func survivesClosing() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle())
        await harness.model.requestCaptcha()
        harness.model.select(2)
        harness.model.next()
        harness.model.select(1)

        harness.clock.advance(10)
        let reopened = sibling(of: harness)
        reopened.prepare()

        #expect(progress(reopened)?.index == 1)
        #expect(progress(reopened)?.selection == 1)
        #expect(reopened.secondsUntilRequest == 20)
        #expect(await harness.browser.loads.count == 1)
    }

    @Test("another thread's form does not get this thread's puzzle, but does wait")
    func otherThreadWaitsToo() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle())
        await harness.model.requestCaptcha()

        let other = sibling(of: harness, thread: 2)
        other.prepare()

        #expect(other.phase == .idle)
        #expect(other.secondsUntilRequest == 30)
    }

    @Test("an expired puzzle is not brought back")
    func expiredIsNotRestored() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(json: puzzle(ttl: 60))
        await harness.model.requestCaptcha()

        harness.clock.advance(60)
        let reopened = sibling(of: harness)
        reopened.prepare()

        #expect(reopened.phase == .idle)
    }

    // MARK: Checks

    @Test("a browser check in the frame is shown, and the puzzle follows it")
    func checkThenPuzzle() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.checkThenReply(Data(puzzle().utf8)))

        await harness.model.requestCaptcha()

        #expect(progress(harness.model) != nil)
    }

    /// The reader may give up on a check and ask again; the first request must
    /// not then come back and overwrite what the second one got.
    @Test("asking again during a check replaces the first request")
    func askingAgainDuringACheck() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.checkAndWait)
        await harness.browser.queueFrame(json: puzzle())

        let first = Task { await harness.model.requestCaptcha() }
        for _ in 0..<500 where harness.model.phase != .checking {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.model.phase == .checking)
        #expect(harness.model.canRequest, "the reader can always ask again during a check")

        await harness.model.requestCaptcha()
        await first.value

        #expect(progress(harness.model) != nil)
        #expect(await harness.browser.loads.count == 2)
    }

    @Test("a further check is asked for, and its token goes with the next request at once")
    func ticketCaptcha() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterTicketCaptcha)))
        await harness.browser.queueFrame(json: puzzle())

        await harness.model.requestCaptcha()
        #expect(harness.model.phase == .ticketCaptcha(siteKey: "00000000-0000-0000-0000-000000000000"))

        // The site asks again the moment its check is answered, cooldown or not.
        await harness.model.ticketCaptchaAnswered("tok")

        let frame = try #require(await harness.browser.loads.last?.frame.absoluteString)
        #expect(frame.contains("ticket_resp=tok"))
        #expect(progress(harness.model) != nil)
    }

    // MARK: Failures

    @Test("the variant this app does not draw is refused plainly")
    func extendedIsRefused() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterExtended)))

        await harness.model.requestCaptcha()

        guard case .failed = harness.model.phase else {
            Issue.record("expected a failure, got \(harness.model.phase)")
            return
        }
        #expect(harness.model.answer == nil)
    }

    @Test("nothing arriving leaves the button free, since the site set no cooldown")
    func timeout() async throws {
        let harness = try makeHarness()
        await harness.browser.queueFrame(.failure(.timedOut))

        await harness.model.requestCaptcha()

        guard case .failed = harness.model.phase else {
            Issue.record("expected a failure, got \(harness.model.phase)")
            return
        }
        #expect(harness.model.canRequest)
    }

    @Test("without a browser engine it says so, and asks for nothing")
    func noBrowser() async throws {
        let harness = try makeHarness(installsBrowser: false)

        await harness.model.requestCaptcha()

        guard case .failed = harness.model.phase else {
            Issue.record("expected a failure, got \(harness.model.phase)")
            return
        }
    }
}
