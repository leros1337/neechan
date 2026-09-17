import Foundation

/// A board and the rules it posts under.
///
/// The `enable_*` flags decide what the reply form may show, so they are
/// surfaced under names that read as capabilities.
public struct Board: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let category: String
    /// Board description shown on the board itself.
    public let info: String
    /// Shorter description used on the front page.
    public let infoOuter: String

    public let threadsPerPage: Int
    public let bumpLimit: Int
    public let maxPages: Int
    public let defaultName: String
    public let maxComment: Int
    /// Total upload allowance per post, in kilobytes, as the server reports it.
    public let maxFilesSizeKB: Int
    /// Extensions the board accepts, for example `jpg`, `webm`, `mp4`.
    public let fileTypes: [String]
    /// Thread tags offered by this board, empty when tags are off.
    public let tags: [String]
    /// Post icons (flags, board-specific badges) offered by this board.
    public let icons: [BoardIcon]

    public let allowsNames: Bool
    public let allowsTripcodes: Bool
    public let allowsSubject: Bool
    public let allowsSage: Bool
    public let allowsIcons: Bool
    public let allowsFlags: Bool
    public let allowsDices: Bool
    public let allowsShield: Bool
    public let allowsThreadTags: Bool
    public let allowsPosting: Bool
    public let allowsLikes: Bool
    public let allowsOekaki: Bool

    /// Whether the board is worksafe.
    ///
    /// Reported only by a site that says; true where nothing says, which keeps
    /// today's behaviour where nothing reads it yet.
    public let isWorkSafe: Bool
    /// Whether the board keeps an archive of its dead threads.
    public let hasArchive: Bool

    public var maxFilesSizeBytes: Int { maxFilesSizeKB * 1024 }

    /// `/b/`, the way the site writes it.
    public var displayCode: String { "/\(id)/" }

    /// Builds a board directly, for a site whose board list is not 2ch's.
    ///
    /// The defaults mirror what `init(from:)` falls back to, so a mapper or a
    /// test names only what it actually knows. `defaultName` is one a second
    /// site will always want to pass: it is the poster name the board shows,
    /// and it is not Russian everywhere.
    public init(
        id: String,
        name: String? = nil,
        category: String = "",
        info: String = "",
        infoOuter: String = "",
        threadsPerPage: Int = 0,
        bumpLimit: Int = 500,
        maxPages: Int = 0,
        defaultName: String = "Аноним",
        maxComment: Int = 15000,
        maxFilesSizeKB: Int = 0,
        fileTypes: [String] = [],
        tags: [String] = [],
        icons: [BoardIcon] = [],
        allowsNames: Bool = false,
        allowsTripcodes: Bool = false,
        allowsSubject: Bool = false,
        allowsSage: Bool = false,
        allowsIcons: Bool = false,
        allowsFlags: Bool = false,
        allowsDices: Bool = false,
        allowsShield: Bool = false,
        allowsThreadTags: Bool = false,
        allowsPosting: Bool = true,
        allowsLikes: Bool = false,
        allowsOekaki: Bool = false,
        isWorkSafe: Bool = true,
        hasArchive: Bool = true
    ) {
        self.id = id
        self.name = name ?? id
        self.category = category
        self.info = info
        self.infoOuter = infoOuter
        self.threadsPerPage = threadsPerPage
        self.bumpLimit = bumpLimit
        self.maxPages = maxPages
        self.defaultName = defaultName
        self.maxComment = maxComment
        self.maxFilesSizeKB = maxFilesSizeKB
        var seen = Set<String>()
        self.fileTypes = fileTypes.filter { seen.insert($0).inserted }
        self.tags = tags
        self.icons = icons
        self.allowsNames = allowsNames
        self.allowsTripcodes = allowsTripcodes
        self.allowsSubject = allowsSubject
        self.allowsSage = allowsSage
        self.allowsIcons = allowsIcons
        self.allowsFlags = allowsFlags
        self.allowsDices = allowsDices
        self.allowsShield = allowsShield
        self.allowsThreadTags = allowsThreadTags
        self.allowsPosting = allowsPosting
        self.allowsLikes = allowsLikes
        self.allowsOekaki = allowsOekaki
        self.isWorkSafe = isWorkSafe
        self.hasArchive = hasArchive
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, category, info
        case infoOuter = "info_outer"
        case threadsPerPage = "threads_per_page"
        case bumpLimit = "bump_limit"
        case maxPages = "max_pages"
        case defaultName = "default_name"
        case maxComment = "max_comment"
        case maxFilesSize = "max_files_size"
        case fileTypes = "file_types"
        case tags, icons
        case enableNames = "enable_names"
        case enableTrips = "enable_trips"
        case enableSubject = "enable_subject"
        case enableSage = "enable_sage"
        case enableIcons = "enable_icons"
        case enableFlags = "enable_flags"
        case enableDices = "enable_dices"
        case enableShield = "enable_shield"
        case enableThreadTags = "enable_thread_tags"
        case enablePosting = "enable_posting"
        case enableLikes = "enable_likes"
        case enableOekaki = "enable_oekaki"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Only `id` is treated as required. The server has added and removed
        // fields before; a client that refuses to decode a board because one
        // flag went missing is worse than one that falls back to a default.
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        info = try c.decodeIfPresent(String.self, forKey: .info) ?? ""
        infoOuter = try c.decodeIfPresent(String.self, forKey: .infoOuter) ?? ""
        threadsPerPage = try c.decodeIfPresent(Int.self, forKey: .threadsPerPage) ?? 0
        bumpLimit = try c.decodeIfPresent(Int.self, forKey: .bumpLimit) ?? 500
        maxPages = try c.decodeIfPresent(Int.self, forKey: .maxPages) ?? 0
        defaultName = try c.decodeIfPresent(String.self, forKey: .defaultName) ?? "Аноним"
        maxComment = try c.decodeIfPresent(Int.self, forKey: .maxComment) ?? 15000
        maxFilesSizeKB = try c.decodeIfPresent(Int.self, forKey: .maxFilesSize) ?? 0
        // The live response repeats "webp" several times; de-duplicate while
        // keeping the server's ordering.
        let rawTypes = try c.decodeIfPresent([String].self, forKey: .fileTypes) ?? []
        var seen = Set<String>()
        fileTypes = rawTypes.filter { seen.insert($0).inserted }
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        icons = try c.decodeIfPresent([BoardIcon].self, forKey: .icons) ?? []

        allowsNames = try c.decodeIfPresent(Bool.self, forKey: .enableNames) ?? false
        allowsTripcodes = try c.decodeIfPresent(Bool.self, forKey: .enableTrips) ?? false
        allowsSubject = try c.decodeIfPresent(Bool.self, forKey: .enableSubject) ?? false
        allowsSage = try c.decodeIfPresent(Bool.self, forKey: .enableSage) ?? false
        allowsIcons = try c.decodeIfPresent(Bool.self, forKey: .enableIcons) ?? false
        allowsFlags = try c.decodeIfPresent(Bool.self, forKey: .enableFlags) ?? false
        allowsDices = try c.decodeIfPresent(Bool.self, forKey: .enableDices) ?? false
        allowsShield = try c.decodeIfPresent(Bool.self, forKey: .enableShield) ?? false
        allowsThreadTags = try c.decodeIfPresent(Bool.self, forKey: .enableThreadTags) ?? false
        allowsPosting = try c.decodeIfPresent(Bool.self, forKey: .enablePosting) ?? true
        allowsLikes = try c.decodeIfPresent(Bool.self, forKey: .enableLikes) ?? false
        allowsOekaki = try c.decodeIfPresent(Bool.self, forKey: .enableOekaki) ?? false
        // 2ch reports neither; the defaults keep every board readable and
        // archived, which is what the app assumed before there was a second
        // site to ask.
        isWorkSafe = true
        hasArchive = true
    }
}

/// An icon a poster may attach (country flag, board badge).
public struct BoardIcon: Sendable, Hashable, Identifiable, Decodable {
    public let num: Int
    public let name: String
    /// Server-relative path to the icon image.
    public let url: String

    public var id: Int { num }

    public init(num: Int, name: String, url: String) {
        self.num = num
        self.name = name
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case num, name, url }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = try c.decodeIfPresent(Int.self, forKey: .num) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}
