import Foundation

/// A post the site refused.
public struct PostingError: Error, Sendable {
    public let code: DvachErrorCode
    /// The site's own wording, which usually carries the specifics.
    public let message: String

    public init(code: DvachErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ apiError: DvachAPIError) {
        self.init(code: apiError.code, message: apiError.message)
    }

    /// True when the captcha must be reloaded before trying again.
    ///
    /// A captcha token is single use, so the form must fetch a new one rather
    /// than let the reader press send twice with the same one.
    public var requiresNewCaptcha: Bool {
        switch code {
        case .invalidCaptcha, .passcodeMissing, .rateLimited: true
        default: false
        }
    }

    /// True when waiting and retrying the same post is reasonable.
    public var isRetryable: Bool {
        switch code {
        case .postingTooFast, .rateLimited, .internalError: true
        default: false
        }
    }

    /// True when the thread can no longer accept posts, so the form should close.
    public var isTerminal: Bool {
        switch code {
        case .threadClosed, .boardClosed, .banned, .noThread, .noBoard, .noAccess: true
        default: false
        }
    }
}
