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
    public let reporting: Bool
    public let passcode: Bool
    /// A catalog the server itself orders by thread creation.
    public let catalogByCreation: Bool
    /// Boards the readers made, listed under their own category.
    public let userBoards: Bool
    public let posting: Bool
    /// Keeping a thread on the device for offline reading.
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
        reporting: true,
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
    /// `savingThreads` is off because the archiver keeps the raw bytes and
    /// re-reads them as 2ch's thread shape; saving a 4chan thread would write a
    /// file nothing can open.
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
        reporting: false,
        passcode: false,
        catalogByCreation: false,
        userBoards: false,
        posting: true,
        savingThreads: false,
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
