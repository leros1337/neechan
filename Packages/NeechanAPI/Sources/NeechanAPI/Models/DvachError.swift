import Foundation

/// A failure reported by 2ch in a JSON envelope (`{"result":0,"error":{…}}`).
public struct DvachAPIError: Error, Sendable, Hashable, Decodable {
    public let code: DvachErrorCode
    /// The server's own wording, in Russian. Shown verbatim when the app has
    /// nothing better to say, because it often carries specifics such as a ban
    /// reason and number.
    public let message: String

    public init(code: DvachErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = DvachErrorCode(rawValue: try container.decodeIfPresent(Int.self, forKey: .code) ?? 0)
        self.message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// The documented error codes, from the official OpenAPI spec (v1.0.31).
///
/// Unrecognised codes are preserved rather than collapsed, so a new server-side
/// code still round-trips and can be reported.
public enum DvachErrorCode: Sendable, Hashable {
    case none
    case forbidden
    case internalError
    case notFound

    case noBoard
    case noThread
    case noPost
    case noAccess
    case boardClosed
    case boardPasscodeOnly
    case invalidCaptcha
    case banned
    case threadClosed
    case postingTooFast
    case fieldTooBig
    case similarFile
    case fileNotSupported
    case fileTooBig
    case tooManyFiles
    case tripcodeBanned
    case wordBanned
    case spamList
    case emptyOriginalPost
    case emptyPost
    case passcodeMissing
    case rateLimited
    case fieldTooSmall

    case wrongStickerID
    case stickerNotFound

    case reportTooManyPosts
    case reportEmpty
    case reportAlreadySent

    case appNotFound
    case appIDWrong
    case appIDExpired
    case appIDSignature
    case appIDUsed

    case unknown(Int)

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .none
        case 403: .forbidden
        case 666: .internalError
        case 667: .notFound
        case -2: .noBoard
        case -3: .noThread
        case -31: .noPost
        case -4: .noAccess
        case -41: .boardClosed
        case -42: .boardPasscodeOnly
        case -5: .invalidCaptcha
        case -6: .banned
        case -7: .threadClosed
        case -8: .postingTooFast
        case -9: .fieldTooBig
        case -10: .similarFile
        case -11: .fileNotSupported
        case -12: .fileTooBig
        case -13: .tooManyFiles
        case -14: .tripcodeBanned
        case -15: .wordBanned
        case -16: .spamList
        case -19: .emptyOriginalPost
        case -20: .emptyPost
        case -21: .passcodeMissing
        case -22: .rateLimited
        case -23: .fieldTooSmall
        case -24: .wrongStickerID
        case -25: .stickerNotFound
        case -50: .reportTooManyPosts
        case -51: .reportEmpty
        case -52: .reportAlreadySent
        case -300: .appNotFound
        case -301: .appIDWrong
        case -302: .appIDExpired
        case -303: .appIDSignature
        case -304: .appIDUsed
        default: .unknown(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .none: 0
        case .forbidden: 403
        case .internalError: 666
        case .notFound: 667
        case .noBoard: -2
        case .noThread: -3
        case .noPost: -31
        case .noAccess: -4
        case .boardClosed: -41
        case .boardPasscodeOnly: -42
        case .invalidCaptcha: -5
        case .banned: -6
        case .threadClosed: -7
        case .postingTooFast: -8
        case .fieldTooBig: -9
        case .similarFile: -10
        case .fileNotSupported: -11
        case .fileTooBig: -12
        case .tooManyFiles: -13
        case .tripcodeBanned: -14
        case .wordBanned: -15
        case .spamList: -16
        case .emptyOriginalPost: -19
        case .emptyPost: -20
        case .passcodeMissing: -21
        case .rateLimited: -22
        case .fieldTooSmall: -23
        case .wrongStickerID: -24
        case .stickerNotFound: -25
        case .reportTooManyPosts: -50
        case .reportEmpty: -51
        case .reportAlreadySent: -52
        case .appNotFound: -300
        case .appIDWrong: -301
        case .appIDExpired: -302
        case .appIDSignature: -303
        case .appIDUsed: -304
        case .unknown(let value): value
        }
    }

    /// True when the request failed because the content is gone, so the caller
    /// should treat the thread or board as deleted rather than retry.
    public var meansMissing: Bool {
        switch self {
        case .noBoard, .noThread, .noPost, .notFound: true
        default: false
        }
    }

    /// True when retrying later could plausibly succeed.
    public var isTransient: Bool {
        switch self {
        case .internalError, .rateLimited, .postingTooFast: true
        default: false
        }
    }
}

/// Everything that can go wrong talking to an imageboard.
public enum DvachError: Error, Sendable {
    /// The server answered with an error envelope.
    case api(DvachAPIError)
    /// A non-2xx HTTP status with no usable envelope.
    case http(status: Int, url: URL?)
    /// The response body was not the JSON we expected.
    case decoding(underlying: String, url: URL?)
    /// Cloudflare (or the site's own gate) served a challenge page. The
    /// associated URL must be opened in a web view so the user can pass it.
    case cloudflareChallenge(url: URL)
    /// The transport failed: offline, TLS, timeout.
    case transport(underlying: any Error)
    /// The selected imageboard does not serve this at all.
    ///
    /// Reached only when something asks for a feature `SiteCapabilities` says
    /// is absent, so it is a programming error rather than a server one — but
    /// it is thrown rather than trapped, because the caller is usually a
    /// background poll and a crash there would be worse than a skipped pass.
    case unsupported(Imageboard)

    /// The API code, when the failure carries one.
    public var code: DvachErrorCode? {
        if case .api(let error) = self { error.code } else { nil }
    }

    /// The server's message, when there is one.
    public var serverMessage: String? {
        if case .api(let error) = self { error.message } else { nil }
    }
}
