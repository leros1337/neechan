import Foundation
import os
import Synchronization

/// Why a request through the browser engine did not come back with an answer.
public enum FourchanBrowserError: Error, Sendable, Equatable {
    /// No browser engine has been installed. Tests, the Mac, a widget.
    case unavailable
    /// Nothing came back in time, and nothing on the way said why.
    case timedOut
    /// A newer request took its place, or the reader left.
    case cancelled
    /// The request left and then failed, so the site may have acted on it.
    case unconfirmed(String)
    case failed(String)
}

/// The browser engine, for the requests 4chan only answers from a page.
///
/// 4chan's posting host sits behind two gates: a script that computes a `_tcs`
/// cookie, and Cloudflare. Both are passed by a browser engine and refused to
/// the app's own `URLSession`, even replaying the very cookies the engine
/// earned. So the captcha and the post go out from a page that the engine has
/// loaded with the board's address, exactly as the site's own reply form
/// sends them.
///
/// This package stays free of WebKit: the layer that has it implements this
/// and installs it in a `FourchanBrowserSlot`.
public protocol FourchanBrowser: Sendable {
    /// Loads the captcha frame in `page` and returns what it posted back.
    ///
    /// - Parameter onCheck: called if the frame shows a browser check, which
    ///   only a person can answer. The call then waits for them rather than
    ///   timing out, and whoever shows the engine's view shows it now.
    /// - Returns: the frame's `twister` object, as JSON.
    func captchaFrame(
        at frame: URL,
        inPage page: URL,
        onCheck: @escaping @Sendable () -> Void
    ) async throws(FourchanBrowserError) -> Data

    /// Sends `request` from `page`, with the engine's cookies, as the site's
    /// own reply form does.
    func send(_ request: URLRequest, fromPage page: URL) async throws(FourchanBrowserError) -> HTTPReply
}

/// Where the browser engine is put once the app has one.
///
/// Built with the services, before any view exists, and filled in by the view
/// layer at launch: the same order the user agent is read in.
public final class FourchanBrowserSlot: Sendable {
    private let browser = Mutex<(any FourchanBrowser)?>(nil)

    public init() {}

    public func install(_ browser: any FourchanBrowser) {
        self.browser.withLock { $0 = browser }
    }

    public var current: (any FourchanBrowser)? {
        browser.withLock { $0 }
    }
}

/// One request for a captcha: which board and thread it is for, and what the
/// site asked to be sent back.
public struct FourchanCaptchaRequest: Sendable, Hashable {
    public let board: String
    /// The thread being replied to; nil when starting one.
    public let thread: Int?
    /// What the site handed out last time, kept and returned on every request.
    public let ticket: String?
    /// The token from a further check the site asked for.
    public let ticketResponse: String?

    /// The live page sends `ext=1`, which lets the site serve a variant this
    /// app does not draw. Without it the site has never been seen to.
    public static let sendsExtendedFlag = false

    public init(board: String, thread: Int?, ticket: String? = nil, ticketResponse: String? = nil) {
        self.board = board
        self.thread = thread
        self.ticket = ticket
        self.ticketResponse = ticketResponse
    }

    private static let endpoints = SiteEndpoints(SiteSelection(site: .fourchan))

    /// The frame, with its query in the order the site's script writes it.
    ///
    /// The ticket goes as stored, unescaped, because that is how the site's
    /// own script appends it; the check's token is escaped.
    public var frameURL: URL {
        var query: [String] = Self.sendsExtendedFlag ? ["ext=1"] : []
        query.append("board=" + escapeBoardCode(board))
        if let thread, thread > 0 { query.append("thread_id=\(thread)") }
        if let ticketResponse, !ticketResponse.isEmpty {
            query.append("ticket_resp=" + Self.escapeComponent(ticketResponse))
        }
        if let ticket, !ticket.isEmpty {
            // A ticket the URL cannot carry as it is would make no URL at all,
            // so that one, and only that one, is escaped after all.
            let raw = "ticket=" + ticket
            let probe = Self.endpoints.posting.absoluteString + "/captcha?" + raw
            query.append(URL(string: probe) == nil ? "ticket=" + Self.escapeComponent(ticket) : raw)
        }
        let address = Self.endpoints.posting.absoluteString + "/captcha?" + query.joined(separator: "&")
        return URL(string: address) ?? Self.endpoints.posting.appending(path: "captcha")
    }

    /// The page the frame sits in: the board, or the thread being replied to,
    /// as the site's own reply form is.
    public var pageURL: URL {
        Self.pageURL(board: board, thread: thread)
    }

    static func pageURL(board: String, thread: Int?) -> URL {
        let base = endpoints.web.appending(path: escapeBoardCode(board), directoryHint: .isDirectory)
        guard let thread, thread > 0 else { return base }
        return base.appending(path: "thread").appending(path: String(thread))
    }

    /// JavaScript's `encodeURIComponent`.
    static func escapeComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Asks 4chan for a captcha, through the browser engine.
///
/// A refusal comes back as a captcha like any other, not as an error: it
/// carries the cooldown the reader has to be shown, and throwing it away was
/// why the app never showed one.
public struct FourchanCaptchaService: Sendable {
    private let browser: FourchanBrowserSlot

    private static let log = Logger(subsystem: Signposts.subsystem, category: "fourchan-captcha")

    public init(browser: FourchanBrowserSlot) {
        self.browser = browser
    }

    public func captcha(
        _ request: FourchanCaptchaRequest,
        onCheck: @escaping @Sendable () -> Void = {}
    ) async throws(FourchanBrowserError) -> FourchanCaptcha {
        guard let browser = browser.current else { throw .unavailable }
        Self.log.notice(
            """
            asking for a captcha: /\(request.board, privacy: .public)/ \
            thread=\(request.thread ?? 0, privacy: .public) \
            ticket=\(request.ticket != nil, privacy: .public) \
            ticketResponse=\(request.ticketResponse != nil, privacy: .public)
            """
        )
        let data = try await browser.captchaFrame(
            at: request.frameURL,
            inPage: request.pageURL,
            onCheck: onCheck
        )
        let captcha: FourchanCaptcha
        do {
            captcha = try JSONDecoder().decode(FourchanCaptcha.self, from: data)
        } catch {
            Self.log.error("captcha unreadable: \(data.count, privacy: .public) bytes")
            throw .failed(
                String(
                    localized: "The captcha came back in a form this app cannot read.",
                    bundle: .module.forAppLanguage(),
                    locale: AppLocale.current
                )
            )
        }
        // Counts and timings only: never a picture, never an answer.
        Self.log.notice(
            """
            captcha answered: steps=\(captcha.steps.count, privacy: .public) \
            ttl=\(captcha.ttl ?? -1, privacy: .public) \
            cd=\(captcha.cooldown ?? -1, privacy: .public) \
            pcd=\(captcha.ticketWait ?? -1, privacy: .public) \
            mpcd=\(captcha.needsTicketCaptcha, privacy: .public) \
            ext=\(captcha.hasExtendedTask, privacy: .public) \
            error=\(captcha.error ?? "none", privacy: .public)
            """
        )
        return captcha
    }
}
