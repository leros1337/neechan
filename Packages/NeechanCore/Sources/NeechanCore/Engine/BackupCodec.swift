import Foundation
import NeechanAPI

/// Everything worth carrying to another device, as one document.
///
/// Deliberately not a database dump: it holds what the reader built up, not
/// cached posts, so it stays small and stays readable if the schema moves on.
public struct NeechanBackup: Codable, Sendable, Equatable {
    /// Bumped when the shape changes in a way older builds cannot read.
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
    public var settings: [String: String]

    public init(
        version: Int = NeechanBackup.currentVersion,
        exportedAt: Date = .now,
        favorites: [FavoriteEntry] = [],
        favoriteBoards: [String] = [],
        favoriteBoardEntries: [FavoriteBoardEntry]? = nil,
        history: [HistoryEntryRecord] = [],
        autohideRules: [AutohideEntry] = [],
        hiddenThreads: [HiddenThreadEntry] = [],
        settings: [String: String] = [:]
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
