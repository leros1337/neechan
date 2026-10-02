import Foundation
import NeechanAPI
import NeechanSettings

/// Everything worth carrying to another device, as one document.
///
/// Deliberately not a database dump: it holds what the reader built up, not
/// cached posts, so it stays small and stays readable if the schema moves on.
public struct NeechanBackup: Codable, Sendable, Equatable {
    /// Bumped when the shape changes in a way older builds cannot read.
    ///
    /// Not bumped for a part added alongside the others: every one of those is
    /// optional, an older build skips what it does not know, and a newer one
    /// finds nothing missing in an older file. The settings, statistics, own
    /// posts, hidden posts, watch state and themes all came that way.
    ///
    /// Version 2 added the imageboard to every entry. The fields are optional
    /// rather than defaulted because `Codable`'s generated decoder throws
    /// `keyNotFound` for a missing key whatever default the property carries,
    /// and `decode` turns any throw into "not a backup" — so a non-optional
    /// field would have made every version 1 file unreadable.
    public static let currentVersion = 2

    /// The imageboard an entry written before there were two belonged to.
    static func resolveSite(_ raw: String?) -> Imageboard {
        raw.flatMap(Imageboard.init(rawValue:)) ?? .dvach
    }

    public struct FavoriteEntry: Codable, Sendable, Equatable {
        public var board: String
        public var threadNum: Int
        public var title: String
        public var customTitle: String?
        public var createdAt: Date
        public var isWatched: Bool
        /// Absent in a file written before there were two imageboards.
        public var site: String?
        /// Where the reader put it in the list. Absent in an older file.
        public var sortOrder: Int?
        /// The opening post's thumbnail, so the list is not blank until the
        /// thread is next opened. Absent in an older file.
        public var opThumbnailPath: String?

        public var key: ThreadKey {
            ThreadKey(site: NeechanBackup.resolveSite(site), board: board, threadNum: threadNum)
        }
    }

    /// A pinned board, with the imageboard it is on.
    ///
    /// Alongside `favoriteBoards` rather than replacing it: that field cannot
    /// change type without making version 1 files unreadable, so version 2
    /// writes both and an older build still finds the 2ch pins where it expects.
    public struct FavoriteBoardEntry: Codable, Sendable, Equatable {
        public var board: String
        public var name: String
        public var site: String?

        public var ref: BoardRef {
            BoardRef(site: NeechanBackup.resolveSite(site), code: board)
        }
    }

    public struct HistoryEntryRecord: Codable, Sendable, Equatable {
        public var board: String
        public var threadNum: Int
        public var title: String
        public var visitedAt: Date
        public var site: String?

        public var key: ThreadKey {
            ThreadKey(site: NeechanBackup.resolveSite(site), board: board, threadNum: threadNum)
        }
    }

    public struct AutohideEntry: Codable, Sendable, Equatable {
        public var pattern: String
        public var isRegularExpression: Bool
        public var matchesSubject: Bool
        public var matchesComment: Bool
        public var matchesName: Bool
        public var matchesFileName: Bool
        public var boards: [String]
        /// Empty or absent means every imageboard, the way `boards` does.
        public var sites: [String]?
        public var appliesToOriginalPostOnly: Bool
        public var appliesToSagedOnly: Bool
        public var isEnabled: Bool
    }

    public struct HiddenThreadEntry: Codable, Sendable, Equatable {
        public var board: String
        public var threadNum: Int
        public var title: String
        public var site: String?

        public var key: ThreadKey {
            ThreadKey(site: NeechanBackup.resolveSite(site), board: board, threadNum: threadNum)
        }
    }

    /// A post the reader made, so it is still marked as theirs.
    public struct OwnPostEntry: Codable, Sendable, Equatable {
        public var board: String
        public var threadNum: Int
        public var postNum: Int
        public var createdAt: Date
        public var site: String?

        public var key: ThreadKey {
            ThreadKey(site: NeechanBackup.resolveSite(site), board: board, threadNum: threadNum)
        }
    }

    /// A post hidden in one thread: by number, with its replies, by name, or
    /// by likeness to some text.
    public struct HiddenPostRuleEntry: Codable, Sendable, Equatable {
        public var board: String
        public var threadNum: Int
        /// `post`, `repliesTree`, `name` or `similar`, as the store keeps it.
        public var kind: String
        public var postNum: Int?
        public var name: String?
        public var similarText: String?
        public var createdAt: Date
        public var site: String?

        public var key: ThreadKey {
            ThreadKey(site: NeechanBackup.resolveSite(site), board: board, threadNum: threadNum)
        }

        public var rule: LocalHideRule? {
            switch kind {
            case "post": postNum.map { .post(num: $0) }
            case "repliesTree": postNum.map { .repliesTree(num: $0) }
            case "name": name.map { .name($0) }
            case "similar": similarText.map { .similar(to: $0) }
            default: nil
            }
        }
    }

    /// Where the reader is in a watched thread, and what the watcher last saw.
    public struct WatchedThreadEntry: Codable, Sendable, Equatable {
        public var board: String
        public var threadNum: Int
        public var site: String?
        public var lastReadPostNum: Int
        public var lastKnownMaxNum: Int
        public var lastKnownPostsCount: Int
        public var unreadCount: Int
        public var readPostsCount: Int
        public var isThreadDeleted: Bool
        public var isClosed: Bool
        public var isArchived: Bool
        public var lastPolledAt: Date
        public var scrollAnchorPostNum: Int?
        public var scrollAnchorOffset: Double

        public var key: ThreadKey {
            ThreadKey(site: NeechanBackup.resolveSite(site), board: board, threadNum: threadNum)
        }
    }

    /// A theme the reader made or imported. The payload is the theme's own
    /// file, kept as it was.
    public struct ThemeEntry: Codable, Sendable, Equatable {
        public var themeID: String
        public var name: String
        public var createdAt: Date
        public var payload: Data
    }

    /// The usage counters on the About screen.
    public struct StatisticsEntry: Codable, Sendable, Equatable {
        public var secondsInApp: Double
        public var postsSent: Int
        public var threadsOpened: Int
    }

    public var version: Int
    public var exportedAt: Date
    public var favorites: [FavoriteEntry]
    public var favoriteBoards: [String]
    /// Version 2 onwards. Absent in an older file, where `favoriteBoards` is
    /// the whole story and every entry is 2ch's.
    public var favoriteBoardEntries: [FavoriteBoardEntry]?
    public var history: [HistoryEntryRecord]
    public var autohideRules: [AutohideEntry]
    public var hiddenThreads: [HiddenThreadEntry]
    /// Preferences, as a flat dictionary of strings.
    ///
    /// Never filled in, and kept only so an older file still decodes:
    /// `preferences` is what carries them.
    public var settings: [String: String]
    /// Every preference that was set, by its defaults key, as its own type.
    public var preferences: [String: PreferenceValue]?
    /// The preferences left at their defaults, which an import resets.
    public var unsetPreferences: [String]?
    public var statistics: StatisticsEntry?
    public var ownPosts: [OwnPostEntry]?
    public var hiddenPostRules: [HiddenPostRuleEntry]?
    public var watchedThreads: [WatchedThreadEntry]?
    public var themes: [ThemeEntry]?

    /// The preferences, in the shape `AppSettings` takes them.
    public var preferencesBackup: PreferencesBackup? {
        preferences.map { PreferencesBackup(values: $0, unset: unsetPreferences ?? []) }
    }

    /// The usage counters, in the shape `AppSettings` takes them.
    public var usageStatistics: UsageStatistics? {
        statistics.map {
            UsageStatistics(
                secondsInApp: $0.secondsInApp, postsSent: $0.postsSent, threadsOpened: $0.threadsOpened
            )
        }
    }

    public init(
        version: Int = NeechanBackup.currentVersion,
        exportedAt: Date = .now,
        favorites: [FavoriteEntry] = [],
        favoriteBoards: [String] = [],
        favoriteBoardEntries: [FavoriteBoardEntry]? = nil,
        history: [HistoryEntryRecord] = [],
        autohideRules: [AutohideEntry] = [],
        hiddenThreads: [HiddenThreadEntry] = [],
        settings: [String: String] = [:],
        preferences: PreferencesBackup? = nil,
        statistics: UsageStatistics? = nil,
        ownPosts: [OwnPostEntry]? = nil,
        hiddenPostRules: [HiddenPostRuleEntry]? = nil,
        watchedThreads: [WatchedThreadEntry]? = nil,
        themes: [ThemeEntry]? = nil
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.favorites = favorites
        self.favoriteBoards = favoriteBoards
        self.favoriteBoardEntries = favoriteBoardEntries
        self.history = history
        self.autohideRules = autohideRules
        self.hiddenThreads = hiddenThreads
        self.settings = settings
        self.preferences = preferences?.values
        self.unsetPreferences = preferences?.unset
        self.statistics = statistics.map {
            StatisticsEntry(
                secondsInApp: $0.secondsInApp, postsSent: $0.postsSent, threadsOpened: $0.threadsOpened
            )
        }
        self.ownPosts = ownPosts
        self.hiddenPostRules = hiddenPostRules
        self.watchedThreads = watchedThreads
        self.themes = themes
    }
}

/// Reads and writes the backup document.
public enum BackupCodec {
    public enum DecodeError: Error, Equatable {
        case notABackup
        case unsupportedVersion(Int)
    }

    public static func encode(_ backup: NeechanBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    public static func decode(_ data: Data) throws -> NeechanBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let backup = try? decoder.decode(NeechanBackup.self, from: data) else {
            throw DecodeError.notABackup
        }
        // A file from a newer build may hold shapes this one cannot read, and
        // importing it half-understood would quietly lose data.
        guard backup.version <= NeechanBackup.currentVersion else {
            throw DecodeError.unsupportedVersion(backup.version)
        }
        return backup
    }

    /// A file name carrying the date, so several exports do not collide.
    public static func suggestedFileName(for date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Neechan-\(formatter.string(from: date)).json"
    }
}
