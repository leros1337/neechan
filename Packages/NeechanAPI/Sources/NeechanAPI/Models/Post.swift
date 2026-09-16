import Foundation

/// A single post, as it appears in a catalog, a board page or a thread.
///
/// Every field except `num` is optional in practice: the same shape is reused
/// across endpoints and the server omits what does not apply. Decoding is
/// therefore total, so one unexpected payload cannot blank a whole thread.
public struct Post: Sendable, Hashable, Identifiable, Decodable {
    public let num: Int
    /// Thread this post belongs to; `0` on an original post.
    public let parent: Int
    public let board: String
    /// Unix time the post was made.
    public let timestamp: Int
    /// Unix time the thread was last bumped.
    public let lastHit: Int
    /// The server's preformatted date, for example `18/01/26 Вск 03:13:04`.
    public let date: String

    /// Comment body, as HTML. Parse with `CommentHTMLParser` before display.
    public let comment: String
    public let subject: String
    public let name: String
    public let email: String
    public let tripcode: String
    /// Inline style the server attaches to an administrative tripcode.
    public let tripcodeStyle: String?
    /// Raw HTML for the poster's icon or country flag.
    public let iconHTML: String?
    /// The icon, read out of that HTML.
    public let icon: PostIcon?
    /// The generated nickname boards with poster IDs give each poster.
    public let posterID: String?
    /// The colour that nickname is shown in, which is how posters are told
    /// apart at a glance.
    public let posterIDColor: PostColor?
    /// Thread tags, as a single comma-separated string.
    public let tags: String

    public let files: [Attachment]

    public let views: Int
    /// Pin priority; `0` means not pinned.
    public let stickyPriority: Int
    public let isEndless: Bool
    public let isClosed: Bool
    /// `1` banned, `2` warned.
    public let bannedState: Int
    /// Whether the poster wore the thread's OP mark.
    public let isOP: Bool
    public let likes: Int?
    public let dislikes: Int?
    /// 1-based position in the thread; only present in thread responses.
    public let number: Int?

    public var id: Int { num }

    /// True when this post opens a thread.
    public var isOriginalPost: Bool { parent == 0 }

    public var isSticky: Bool { stickyPriority > 0 }

    /// True when the poster sent the post with sage, so it did not bump.
    public var isSage: Bool {
        email.lowercased() == "sage" || email.lowercased().hasPrefix("sage")
    }

    public var isBanned: Bool { bannedState == 1 }
    public var isWarned: Bool { bannedState == 2 }

    public var hasAttachments: Bool { !files.isEmpty }

    public var postedAt: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    /// The thread this post lives in: its own number when it is the original post.
    public var threadNum: Int { isOriginalPost ? num : parent }

    private enum CodingKeys: String, CodingKey {
        case num, parent, board, timestamp, lasthit, date
        case comment, subject, name, email, trip
        case tripStyle = "trip_style"
        case icon, tags, files, views, sticky, endless, closed, banned, op
        case likes, dislikes, number
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = try c.decode(Int.self, forKey: .num)
        parent = try Post.flexibleInt(c, .parent) ?? 0
        board = try c.decodeIfPresent(String.self, forKey: .board) ?? ""
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
        lastHit = try c.decodeIfPresent(Int.self, forKey: .lasthit) ?? 0
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""

        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        // These arrive HTML-escaped but outside any markup, so they are
        // unescaped here; the comment keeps its entities because the parser
        // needs them alongside its tags.
        subject = HTMLEntities.decode(try c.decodeIfPresent(String.self, forKey: .subject) ?? "")

        // The name can carry a span with the poster's generated nickname, so it
        // is parsed rather than merely unescaped.
        let posterName = PosterName(
            html: try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        )
        name = posterName.displayName
        posterID = posterName.posterID
        posterIDColor = posterName.posterIDColor
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        tripcode = HTMLEntities.decode(try c.decodeIfPresent(String.self, forKey: .trip) ?? "")
        tripcodeStyle = try c.decodeIfPresent(String.self, forKey: .tripStyle)
        iconHTML = try c.decodeIfPresent(String.self, forKey: .icon)
        icon = iconHTML.flatMap(PostIcon.init(html:))
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""

        // `files` is sometimes null rather than absent.
        files = try c.decodeIfPresent([Attachment].self, forKey: .files) ?? []

        views = try c.decodeIfPresent(Int.self, forKey: .views) ?? 0
        stickyPriority = try c.decodeIfPresent(Int.self, forKey: .sticky) ?? 0
        isEndless = (try c.decodeIfPresent(Int.self, forKey: .endless) ?? 0) != 0
        isClosed = (try c.decodeIfPresent(Int.self, forKey: .closed) ?? 0) != 0
        bannedState = try c.decodeIfPresent(Int.self, forKey: .banned) ?? 0
        isOP = (try c.decodeIfPresent(Int.self, forKey: .op) ?? 0) != 0
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        dislikes = try c.decodeIfPresent(Int.self, forKey: .dislikes)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
    }

    /// `parent` arrives as a number in most responses and as a string in a few
    /// archived ones.
    private static func flexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(text)
        }
        return nil
    }
}
