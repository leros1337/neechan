import Foundation

/// Which captcha a site puts in front of posting.
///
/// An enum rather than a flag because the reply form needs to know *which*
/// control to draw, not merely whether to draw one.
public enum CaptchaKind: Sendable, Hashable {
    /// 2ch's emoji keyboard, with its proof of work.
    case emoji
    /// 4chan's slider puzzle. Solved by the reader, never by the app.
    case slider
    case none
}

/// Which markup a site's reply form writes.
///
/// An enum for the same reason as `CaptchaKind`: the toolbar needs the dialect,
/// not a yes or no.
public enum MarkupDialect: Sendable, Hashable {
    /// 2ch's wakaba dialect: `**bold**`, `%%spoiler%%`, `[code]`.
    case wakaba
    /// 4chan's: greentext everywhere, and `[code]`/`[math]`/`[spoiler]` only
    /// where the board says so.
    case fourchan
}

/// How a site takes a report.
///
/// An enum rather than a flag, for the same reason as ``CaptchaKind``: the post
/// menu offers one action, but the two sites answer it with different screens.
public enum ReportingStyle: Sendable, Hashable {
    /// A call the app makes itself. 2ch's `POST /user/report`.
    case api
    /// The site's own report page, opened in a web view.
    ///
    /// 4chan's form is on the posting host behind its T-Captcha — the same
    /// gate that already refuses this app's posts — so the page the reader
    /// fills in has to be the real one.
    case web
    case none
}

/// What one imageboard can do.
///
/// Views gate on a capability rather than on the site, so a third imageboard
/// needs no edits to any view. Two deliberate exceptions live in the settings
/// screens: the mirror picker is literally a `DvachDomain` control, and copy
/// that names a site has to name it.
public struct SiteCapabilities: Sendable, Hashable {
    /// Fetching only the posts added since a known one.
    public let incrementalThreadRefresh: Bool
    /// A poll that returns a thread's post count and nothing else.
    public let cheapThreadPoll: Bool
    /// A poll that covers every thread on a board in one request.
    public let boardWidePoll: Bool
    /// Fetching one post by number, without its thread.
    public let singlePostLookup: Bool
    public let serverSearch: Bool
    public let archive: Bool
    /// Whether an archive row carries a title and a date, or only a number.
    public let archiveCarriesTitles: Bool
    public let voting: Bool
    public let reporting: ReportingStyle
    public let passcode: Bool
    /// A catalog the server itself orders by thread creation.
    public let catalogByCreation: Bool
    /// Boards the readers made, listed under their own category.
    public let userBoards: Bool
    public let posting: Bool
    /// Keeping a thread on the device for offline reading.
    ///
    /// On for both sites. It was 2ch-only for as long as the archiver read
    /// every saved file as 2ch's shape; it now reads each one the way the site
    /// that wrote it writes threads, which the saved row has recorded all
    /// along.
    public let savingThreads: Bool
    public let captcha: CaptchaKind
    public let markup: MarkupDialect

    public static let dvach = SiteCapabilities(
        incrementalThreadRefresh: true,
        cheapThreadPoll: true,
        boardWidePoll: false,
        singlePostLookup: true,
        serverSearch: true,
        archive: true,
        archiveCarriesTitles: true,
        voting: true,
        reporting: .api,
        passcode: true,
        catalogByCreation: true,
        userBoards: true,
        posting: true,
        savingThreads: true,
        captcha: .emoji,
        markup: .wakaba
    )

    /// 4chan serves a static JSON API and nothing else: no incremental refresh,
    /// no count-only poll, no search, no voting. What it does have is
    /// `threads.json`, which answers for a whole board at once and is cheaper
    /// than 2ch's per-thread poll.
    ///
    /// `reporting` is `.web` rather than `.none`: 4chan has no report API, but
    /// it does have a report *page*, and that page is the one thing on the
    /// posting host the app can still put in front of a reader — the browser
    /// engine passes the gate that the app's own requests cannot.
    ///
    /// `posting` is on, and is known not to reach the site today. 4chan's
    /// posting host sits behind its own gate — a script that computes a `_tcs`
    /// cookie in the browser — and the server refuses that cookie when the
    /// app's own requests replay it, even with everything else identical. So
    /// the reply form opens, the captcha is asked for, and the browser check
    /// appears and does not let go. It is left reachable on purpose: the whole
    /// path is written and tested, and hiding it would mean the day the gate
    /// changes nobody would find out. Reading is unaffected — the JSON host has
    /// no gate at all.
    public static let fourchan = SiteCapabilities(
        incrementalThreadRefresh: false,
        cheapThreadPoll: false,
        boardWidePoll: true,
        singlePostLookup: false,
        serverSearch: false,
        archive: true,
        archiveCarriesTitles: false,
        voting: false,
        reporting: .web,
        passcode: false,
        catalogByCreation: false,
        userBoards: false,
        posting: true,
        savingThreads: true,
        captcha: .slider,
        markup: .fourchan
    )

    /// Pure and nonisolated, so a main-actor view can read it without awaiting.
    public static func of(_ site: Imageboard) -> SiteCapabilities {
        switch site {
        case .dvach: .dvach
        case .fourchan: .fourchan
        }
    }
}
