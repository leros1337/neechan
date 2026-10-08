import Foundation
import NeechanAPITesting
import NeechanTestSupport
import Synchronization
import Testing
@testable import NeechanAPI

/// Asking for a captcha the way the site's own page does.
///
/// None of these answers one. They check where the frame is loaded from, what
/// travels with it, and that what comes back is handed on whole — a refusal
/// included, since its cooldown is the one thing the reader needs to see.
@Suite("4chan captcha through the browser")
struct FourchanCaptchaServiceTests {
    private func service(_ browser: FakeFourchanBrowser?) -> FourchanCaptchaService {
        let slot = FourchanBrowserSlot()
        if let browser { slot.install(browser) }
        return FourchanCaptchaService(browser: slot)
    }

    @Test("a reply's frame names the board and the thread, on the posting host")
    func replyFrame() {
        let request = FourchanCaptchaRequest(board: "po", thread: 123)
        #expect(request.frameURL.absoluteString == "https://sys.4chan.org/captcha?board=po&thread_id=123")
        #expect(request.pageURL.absoluteString == "https://boards.4chan.org/po/thread/123")
    }

    @Test("a new thread's frame names no thread, and sits on the board's page")
    func newThreadFrame() {
        let request = FourchanCaptchaRequest(board: "po", thread: nil)
        #expect(request.frameURL.absoluteString == "https://sys.4chan.org/captcha?board=po")
        #expect(request.pageURL.absoluteString == "https://boards.4chan.org/po/")
    }

    /// In the order the site's script writes them, with the ticket as stored
    /// and the check's token escaped, as that script does.
    @Test("the ticket goes back as stored, and the check's token escaped")
    func ticketAndResponse() {
        let request = FourchanCaptchaRequest(
            board: "po", thread: 7, ticket: "a+b/c=", ticketResponse: "P1 e+J/x="
        )
        #expect(
            request.frameURL.absoluteString
                == "https://sys.4chan.org/captcha?board=po&thread_id=7&ticket_resp=P1%20e%2BJ%2Fx%3D&ticket=a+b/c="
        )
    }

    @Test("the variant this app does not draw is not asked for")
    func noExtendedFlag() {
        #expect(FourchanCaptchaRequest(board: "po", thread: nil).frameURL.query()?.contains("ext") == false)
    }

    @Test("the frame is loaded in the page it belongs to, and its reply read")
    func loadsTheFrame() async throws {
        let browser = FakeFourchanBrowser()
        await browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterTasksSmall)))

        let captcha = try await service(browser).captcha(FourchanCaptchaRequest(board: "po", thread: 1))

        #expect(captcha.steps.count == 2)
        let load = try #require(await browser.loads.first)
        #expect(load.frame.absoluteString == "https://sys.4chan.org/captcha?board=po&thread_id=1")
        #expect(load.page.absoluteString == "https://boards.4chan.org/po/thread/1")
    }

    /// What used to happen instead: the refusal was thrown, its cooldown with
    /// it, and the reader was shown neither.
    @Test("a refusal comes back with its cooldown, not as an error")
    func refusalKeepsItsCooldown() async throws {
        let browser = FakeFourchanBrowser()
        await browser.queueFrame(.reply(try FixtureLoader.data(.fourchanTwisterRefused)))

        let captcha = try await service(browser).captcha(FourchanCaptchaRequest(board: "po", thread: nil))

        #expect(captcha.cooldown == 300)
        #expect(captcha.outcome == .refused("You have to wait a while before doing this again."))
    }

    @Test("a browser check in the frame is passed on to whoever shows it")
    func checkIsPassedOn() async throws {
        let browser = FakeFourchanBrowser()
        await browser.queueFrame(.checkThenReply(try FixtureLoader.data(.fourchanTwisterNoop)))
        let checks = Mutex(0)

        _ = try await service(browser).captcha(FourchanCaptchaRequest(board: "po", thread: nil)) {
            checks.withLock { $0 += 1 }
        }

        #expect(checks.withLock { $0 } == 1)
    }

    @Test("without a browser engine nothing is asked for, and it says so")
    func unavailable() async {
        do {
            _ = try await service(nil).captcha(FourchanCaptchaRequest(board: "po", thread: nil))
            Issue.record("expected the browser to be missing")
        } catch {
            #expect(error == .unavailable)
        }
    }

    @Test("a reply that is not the frame's object is reported, not guessed at")
    func unreadable() async {
        let browser = FakeFourchanBrowser()
        await browser.queueFrame(.reply(Data("<html>".utf8)))
        do {
            _ = try await service(browser).captcha(FourchanCaptchaRequest(board: "po", thread: nil))
            Issue.record("expected an unreadable reply")
        } catch {
            guard case .failed = error else {
                Issue.record("expected a failure, got \(error)")
                return
            }
        }
    }

    /// The JSON hosts have no gate, the posting host has two, and only a
    /// browser engine passes those. Anything the client sends itself must
    /// therefore stay off it.
    @Test("nothing the client builds for 4chan goes to the posting host")
    func clientNeverTouchesThePostingHost() {
        let site = SiteSelection(site: .fourchan)
        let endpoints: [ImageboardEndpoint] = [
            .boards,
            .catalog(board: "g"),
            .catalogByCreation(board: "g"),
            .boardPage(board: "g", page: 1),
            .boardThreads(board: "g"),
            .thread(board: "g", thread: 1),
            .archiveIndex(board: "g"),
            .archivePage(board: "g", page: 0),
            .archiveThread(board: "g", thread: 1),
            .post(board: "g", num: 2, inThread: 1),
        ]
        for endpoint in endpoints {
            let host = endpoint.request(for: site)?.url?.host()
            #expect(host != "sys.4chan.org", "\(endpoint) went to the posting host")
        }
    }
}
