import Foundation

/// A recorded response used by the test suites.
///
/// Fixtures live in `Sources/NeechanTestSupport/Fixtures` and are re-recorded
/// with `Tools/record-fixtures.sh` (2ch) and `Tools/record-4chan-fixtures.sh`. Referring to them through this enum (rather
/// than by raw string) means a renamed or deleted fixture is a compile error.
public enum Fixture: String, CaseIterable, Sendable {
    // Read endpoints
    case boards
    case catalog
    case indexPage0 = "index_page0"
    case indexPage1 = "index_page1"
    case thread
    case threadAfter = "thread_after"
    case threadAfterEmpty = "thread_after_empty"
    case threadInfo = "thread_info"
    case postSingle = "post_single"
    case errorNoPost = "error_no_post"
    case searchResult = "search_result"
    case searchTooShort = "search_too_short"
    case archiveIndex = "archive_index"

    /// A second of VP9 video with Opus audio, the shape 2ch serves, generated
    /// rather than recorded so it stays tiny and always decodes to the same
    /// thing. Used by the WebM converter's tests.
    case sampleVideo = "sample_video"

    // Captcha
    case captchaSettings = "captcha_settings"
    case captchaEmojiID = "captcha_emoji_id"
    case captchaEmojiIDPasscode = "captcha_emoji_id_passcode"
    case captchaEmojiShow = "captcha_emoji_show"
    case captchaEmojiClickStep = "captcha_emoji_click_step"
    case captchaEmojiClickSuccess = "captcha_emoji_click_success"
    case powCase = "pow_case"

    // Write endpoints
    case postingPostOK = "posting_post_ok"
    case postingThreadOK = "posting_thread_ok"
    case postingErrorCaptcha = "posting_error_captcha"
    case postingErrorBanned = "posting_error_banned"
    case postingErrorThreadClosed = "posting_error_thread_closed"
    case passloginOK = "passlogin_ok"
    case passloginError = "passlogin_error"
    case reportOK = "report_ok"
    case likeForbidden = "like_forbidden"

    // 4chan read endpoints
    case fourchanBoards = "fourchan_boards"
    case fourchanCatalog = "fourchan_catalog"
    case fourchanIndexPage1 = "fourchan_index_page1"
    case fourchanThread = "fourchan_thread"
    /// Every thread on a board with its reply count: the watcher's whole pass.
    case fourchanThreadsIndex = "fourchan_threads_index"
    /// A bare array of thread numbers, which is all 4chan's archive is.
    case fourchanArchive = "fourchan_archive"

    // 4chan captcha
    ///
    /// Synthesized rather than recorded: the live endpoint sits behind a
    /// browser check, so a served captcha cannot be fetched here.
    case fourchanCaptchaChallenge = "fourchan_captcha_challenge"
    case fourchanCaptchaCooldown = "fourchan_captcha_cooldown"
    /// The real page the captcha endpoint answers with while the gate is up.
    case fourchanCloudflareGate = "fourchan_cloudflare_gate"

    // Corpora / non-JSON
    case commentSamples = "comment_samples"
    case cloudflareChallenge = "cloudflare_challenge"
    case themeDashchan = "theme_dashchan"

    // Media
    case sampleStillPNG = "sample_still"
    case sampleAnimatedGIF = "sample_animated"

    /// File extension on disk. Everything is JSON except the HTML challenge page.
    public var fileExtension: String {
        switch self {
        case .cloudflareChallenge, .fourchanCloudflareGate: "html"
        case .sampleStillPNG: "png"
        case .sampleAnimatedGIF: "gif"
        case .sampleVideo: "webm"
        default: "json"
        }
    }

    public var isJSON: Bool { fileExtension == "json" }
}
