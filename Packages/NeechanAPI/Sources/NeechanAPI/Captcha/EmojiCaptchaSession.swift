import Foundation

/// Runs one emoji captcha from start to solved token.
///
/// The site's captcha is a sequence: each tap either advances to a new keyboard
/// or finishes. The session holds the token that ties the steps together, and
/// the proof-of-work challenge that must be solved alongside it.
public actor EmojiCaptchaSession {
    /// Where the captcha has got to.
    public enum State: Sendable {
        /// Another keyboard to answer.
        case challenge(EmojiCaptchaStep)
        /// Solved; send this as `emoji_captcha_id`.
        case solved(String)
        /// No captcha is needed at all.
        case notRequired(NotRequiredReason)
    }

    public enum NotRequiredReason: Sendable, Equatable {
        /// A passcode is active, so the site waives the captcha.
        case passcode
        /// The board has captcha switched off.
        case disabled
    }

    public enum CaptchaError: Error, CustomStringConvertible {
        case notStarted
        case expired
        case rejected(String)

        public var description: String {
            switch self {
            case .notStarted: "The captcha has not been started."
            case .expired: "The captcha expired. Load a new one."
            case .rejected(let message): message
            }
        }
    }

    private let client: DvachClient
    private var tokenID: String?
    /// The proof of work the post must carry alongside the captcha token.
    public private(set) var proofOfWorkChallenge: CaptchaChallenge?
    /// When the captcha token stops being accepted.
    public private(set) var expiresAt: Date?
    /// Raised upload limits, when the site reports them for a passcode.
    public private(set) var maxFiles: Int?
    public private(set) var maxFilesSizeKB: Int?

    public init(client: DvachClient) {
        self.client = client
    }

    /// Requests a captcha for a board, and a thread when replying to one.
    public func start(board: String, thread: Int?) async throws -> State {
        reset()

        let response: CaptchaIDResponse = try await client.captchaID(board: board, thread: thread)

        if let banned = response.banned, !banned.isEmpty {
            throw CaptchaError.rejected(banned)
        }

        // The site signals its own outcomes through `result`, not HTTP status.
        switch response.result {
        case 2:
            maxFiles = response.maxFiles
            maxFilesSizeKB = response.maxFilesSize
            return .notRequired(.passcode)
        case 3:
            return .notRequired(.disabled)
        case -1, 4:
            throw CaptchaError.expired
        case 1:
            break
        default:
            throw CaptchaError.rejected(
                response.error?.message
                    ?? String(localized: "The captcha could not be loaded.", bundle: .module, locale: AppLocale.current)
            )
        }

        guard let id = response.id, !id.isEmpty else { throw CaptchaError.expired }
        tokenID = id
        proofOfWorkChallenge = response.challenge
        // The observed lifetime is five minutes; the form counts down from here.
        expiresAt = Date.now.addingTimeInterval(300)

        let step = try await client.emojiCaptchaShow(id: id)
        return .challenge(step)
    }

    /// Answers the current keyboard.
    ///
    /// - Parameter index: zero-based position in `keyboard`, which is how the
    ///   site numbers them.
    public func select(emojiAt index: Int) async throws -> State {
        guard let tokenID else { throw CaptchaError.notStarted }
        return try await client.emojiCaptchaClick(id: tokenID, emojiIndex: index)
    }

    /// The solved proof of work, or nil when there was no challenge to solve.
    public func solveProofOfWork() async -> Int? {
        guard let proofOfWorkChallenge else { return nil }
        return await ProofOfWork.solve(proofOfWorkChallenge)
    }

    public func reset() {
        tokenID = nil
        proofOfWorkChallenge = nil
        expiresAt = nil
        maxFiles = nil
        maxFilesSizeKB = nil
    }
}
