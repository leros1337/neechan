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
    ///
    /// VP9 profile 1, which no VideoToolbox decoder will take, so this one
    /// always goes through software.
    case sampleVideo = "sample_video"

    /// VP9 profile 0 with Opus, the profile a phone's own decoder can take.
    /// The counterpart to `sampleVideo`, for the hardware path.
    case sampleVP9Profile0 = "sample_vp9_p0"
    /// VP8 with Opus. No hardware decoder exists for VP8 anywhere.
    case sampleVP8 = "sample_vp8"
    /// H.264 High with B-frames and AAC, so frames arrive out of display order.
    case sampleH264 = "sample_h264"
    /// HEVC tagged `hev1` with MP3 audio: the shape 2ch serves and the one
    /// AVFoundation refuses to open at all.
    case sampleHEV1 = "sample_hev1"
    /// H.264 with FLAC in a Matroska file, which is what a `.mkv` usually is:
    /// the same container as WebM carrying codecs WebM never does.
    case sampleMatroska = "sample_matroska"

    /// VP9 with no sound at all. Boards are full of these, and a player that
    /// waits for an audio clock it will never get shows a frozen picture.
    case sampleVideoOnly = "sample_videoonly"
    /// Opus with no picture, which is the same problem the other way round.
    case sampleAudioOnly = "sample_audioonly"

    /// VP9 with sound in a format the app's FFmpeg build cannot decode.
    ///
    /// Deliberately so: the build is trimmed, and a file from elsewhere may
    /// carry anything. A clip whose sound will not decode must still play and
    /// still end, rather than running its timeline on for ever because one
    /// half of it never reported that it had finished.
    case sampleUndecodableAudio = "sample_deafaudio"

    /// Twelve seconds of VP9 and Opus.
    ///
    /// Long enough that the renderer empties what it was given at the start
    /// and has to be fed again, which every one-second fixture is too short to
    /// ever ask for. A player that stops halfway through a clip stops here.
    case sampleLong = "sample_long"

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
    case reportAlreadySent = "report_already_sent"
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
        case .sampleVideo, .sampleVP9Profile0, .sampleVP8,
             .sampleVideoOnly, .sampleAudioOnly, .sampleLong: "webm"
        case .sampleH264, .sampleHEV1: "mp4"
        case .sampleMatroska, .sampleUndecodableAudio: "mkv"
        default: "json"
        }
    }

    public var isJSON: Bool { fileExtension == "json" }
}
