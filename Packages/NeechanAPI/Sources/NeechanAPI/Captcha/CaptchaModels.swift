import Foundation

/// The proof-of-work the site attaches to a captcha.
///
/// Undocumented, and read out of the site's own `board.js`: the client must
/// find the integer whose substitution into `template` hashes to `hash`, and
/// send it with the post. Without it the post is rejected.
public struct CaptchaChallenge: Sendable, Hashable, Decodable {
    /// Lowercase hexadecimal SHA-512 of the solved template.
    public let hash: String
    /// Exclusive upper bound on the search, as the server sets it.
    public let limit: Int
    /// Contains `%d`, which is replaced by the candidate number.
    public let template: String

    public init(hash: String, limit: Int, template: String) {
        self.hash = hash
        self.limit = limit
        self.template = template
    }
}

/// `GET /api/captcha/emoji/id`
public struct CaptchaIDResponse: Sendable, Decodable {
    public let result: Int
    public let id: String?
    public let type: String?
    public let input: String?
    public let challenge: CaptchaChallenge?
    /// Present for passcode holders: their raised upload allowance.
    public let maxFiles: Int?
    public let maxFilesSize: Int?
    /// Free text the site wants shown to the reader.
    public let warning: String?
    public let banned: String?
    public let error: DvachAPIError?
}

/// `GET /api/captcha/emoji/show` and the reply to each `click`.
///
/// One shape or the other: another step to solve, or the token that proves it
/// is solved.
public struct EmojiCaptchaStep: Sendable, Decodable {
    /// Base64 PNG of the symbols to find.
    public let image: String
    /// Base64 PNGs of the keys to choose from.
    public let keyboard: [String]

    public init(image: String, keyboard: [String]) {
        self.image = image
        self.keyboard = keyboard
    }
}

struct EmojiCaptchaReply: Decodable {
    let image: String?
    let keyboard: [String]?
    /// The captcha token, once solved.
    let success: String?
    let error: DvachAPIError?
}

/// `GET /api/captcha/settings/{board}`
public struct CaptchaSettings: Sendable, Decodable {
    public let enabled: Int
    public let result: Int

    public var isEnabled: Bool { enabled != 0 }
}
