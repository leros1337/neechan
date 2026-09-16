import Foundation

/// Everything needed to send one post.
public struct PostingRequest: Sendable {
    /// A file to attach.
    public struct Attachment: Sendable {
        public let fileName: String
        public let mimeType: String
        public let data: Data

        public init(fileName: String, mimeType: String, data: Data) {
            self.fileName = fileName
            self.mimeType = mimeType
            self.data = data
        }
    }

    /// How the post proves it is not a script.
    public enum Captcha: Sendable {
        /// A solved emoji captcha, with the proof of work the site also wants.
        case emoji(token: String, proofOfWork: Int?)
        /// A passcode is active; the cookie does the proving.
        case passcode
        /// The board asks for nothing.
        case none

        var typeField: String {
            switch self {
            case .emoji: "emoji_captcha"
            case .passcode: "passcode"
            case .none: "nocaptcha"
            }
        }
    }

    public var board: String
    /// The thread to reply to; nil creates one.
    public var thread: Int?
    public var comment: String
    public var subject: String?
    /// May carry a tripcode as `name#secret`.
    public var name: String?
    public var email: String?
    /// Thread tag, on boards that use them.
    public var tags: String?
    /// Poster icon or flag, by its number on the board.
    public var icon: Int?
    public var isSage: Bool
    /// Marks the post as the thread's original poster.
    public var isOriginalPoster: Bool
    public var attachments: [Attachment]
    public var captcha: Captcha

    public init(
        board: String,
        thread: Int? = nil,
        comment: String,
        subject: String? = nil,
        name: String? = nil,
        email: String? = nil,
        tags: String? = nil,
        icon: Int? = nil,
        isSage: Bool = false,
        isOriginalPoster: Bool = false,
        attachments: [Attachment] = [],
        captcha: Captcha = .none
    ) {
        self.board = board
        self.thread = thread
        self.comment = comment
        self.subject = subject
        self.name = name
        self.email = email
        self.tags = tags
        self.icon = icon
        self.isSage = isSage
        self.isOriginalPoster = isOriginalPoster
        self.attachments = attachments
        self.captcha = captcha
    }

    /// True when the site would reject this as empty.
    public var isEmpty: Bool {
        comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// The form the site expects, in the order its own page sends it.
    func formFields() -> [(String, String)] {
        var fields: [(String, String)] = [
            ("task", "post"),
            ("board", board),
            ("thread", String(thread ?? 0)),
            ("captcha_type", captcha.typeField),
            ("comment", comment),
        ]

        if case .emoji(let token, let proofOfWork) = captcha {
            fields.append(("emoji_captcha_id", token))
            if let proofOfWork {
                fields.append(("2ch_challenge", String(proofOfWork)))
            }
        }

        if let subject, !subject.isEmpty { fields.append(("subject", subject)) }
        if let name, !name.isEmpty { fields.append(("name", name)) }
        if let tags, !tags.isEmpty { fields.append(("tags", tags)) }
        if let icon { fields.append(("icon", String(icon))) }
        if isOriginalPoster { fields.append(("op_mark", "1")) }

        // Sage travels in the email field, exactly as the site's own form sends
        // it; there is no separate flag in the API.
        if isSage {
            fields.append(("email", "sage"))
        } else if let email, !email.isEmpty {
            fields.append(("email", email))
        }

        return fields
    }
}

/// What came back from a successful post.
public enum PostingOutcome: Sendable, Equatable {
    case posted(num: Int)
    case threadCreated(num: Int)

    /// The thread to open afterwards, given the thread that was replied to.
    public func threadNum(repliedTo thread: Int?) -> Int {
        switch self {
        case .posted: thread ?? 0
        case .threadCreated(let num): num
        }
    }
}
