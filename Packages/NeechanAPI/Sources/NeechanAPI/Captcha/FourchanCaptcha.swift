import Foundation

/// 4chan's slider captcha, as the site serves it.
///
/// Two stacked images: `image` is the puzzle and `background` slides behind it
/// until the characters line up, at which point the reader types them. Solving
/// it is the reader's job and only the reader's — nothing in this app computes
/// an offset or guesses a character, and nothing should.
///
/// Undocumented: the shape is taken from the site's own `captcha.js`.
public struct FourchanCaptcha: Sendable, Decodable, Hashable {
    /// The token that travels back with the answer as `t-challenge`.
    ///
    /// The literal string `noop` means the reader does not have to solve
    /// anything — a pass, or a board that is not asking right now.
    public let challenge: String?
    /// Base64 PNG: the characters, on a transparent strip.
    public let image: String?
    /// Base64 PNG: the background that slides behind them. Absent on the
    /// easier variant, where the strip is already legible.
    public let background: String?
    public let imageWidth: Int?
    public let backgroundWidth: Int?
    /// How long the token is good for, in seconds.
    public let ttl: Int?
    /// Seconds to wait before asking again, when the site is refusing.
    public let cooldown: Int?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case challenge, ttl, error
        case image = "img"
        case background = "bg"
        case imageWidth = "img_width"
        case backgroundWidth = "bg_width"
        case cooldown = "cd"
    }

    /// True when the site says no captcha is needed.
    public var isNotRequired: Bool { challenge == "noop" }

    /// True when there is a puzzle for the reader to answer.
    public var isSolvable: Bool {
        guard let challenge, !challenge.isEmpty, challenge != "noop" else { return false }
        return image?.isEmpty == false
    }

    /// Read field by field, tolerating what the wire actually carries.
    ///
    /// The endpoint is undocumented and reverse-engineered, and the models this
    /// app decodes elsewhere are deliberately total for the same reason: one
    /// field arriving as a number where a string was expected must not turn
    /// into "the site sent something this app could not read", which tells the
    /// reader nothing they can act on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        challenge = Self.string(container, .challenge)
        image = Self.string(container, .image)
        background = Self.string(container, .background)
        imageWidth = Self.int(container, .imageWidth)
        backgroundWidth = Self.int(container, .backgroundWidth)
        ttl = Self.int(container, .ttl)
        cooldown = Self.int(container, .cooldown)
        error = Self.string(container, .error)
    }

    private static func string(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    private static func int(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        // A cooldown has been seen with a fractional part.
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(text) ?? Double(text).map { Int($0.rounded()) }
        }
        return nil
    }

    public init(
        challenge: String? = nil,
        image: String? = nil,
        background: String? = nil,
        imageWidth: Int? = nil,
        backgroundWidth: Int? = nil,
        ttl: Int? = nil,
        cooldown: Int? = nil,
        error: String? = nil
    ) {
        self.challenge = challenge
        self.image = image
        self.background = background
        self.imageWidth = imageWidth
        self.backgroundWidth = backgroundWidth
        self.ttl = ttl
        self.cooldown = cooldown
        self.error = error
    }
}
