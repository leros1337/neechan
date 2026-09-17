import Foundation
import NeechanAPI
import SwiftData

/// The live schema: every record says which imageboard it belongs to.
///
/// V1 knew one site, so `/b/12345` was a thread. With two, it is two threads
/// that happen to be written the same way, and `FavoriteBoard` — unique on the
/// board code alone — would have let pinning 4chan's `/b/` overwrite the 2ch
/// pin with no error at all. Moving the uniqueness onto `(site, board, …)` is
/// what the whole version exists for.
///
/// The models are nested for the reason `NeechanSchemaV1`'s are; the
/// `typealias`es at the bottom of this file are what the rest of the app sees,
/// so no repository, view or test names a version.
public enum NeechanSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            HistoryEntry.self,
            WatchedThreadState.self,
            Draft.self,
            DraftAttachment.self,
            OwnPost.self,
            Favorite.self,
            FavoriteBoard.self,
            HiddenThread.self,
            HiddenPostRule.self,
            AutohideRule.self,
            SavedThread.self,
            StoredTheme.self,
        ]
    }

    /// A thread the reader opened.
    @Model
    public final class HistoryEntry {
        #Unique<HistoryEntry>([\.siteRaw, \.board, \.threadNum])
        #Index<HistoryEntry>([\.visitedAt], [\.siteRaw, \.board, \.threadNum])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var threadNum: Int = 0
        public var title: String = ""
        public var visitedAt: Date = Date.distantPast
        /// Server-relative path to the thread's first thumbnail.
        public var thumbnailPath: String?

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public var key: ThreadKey { ThreadKey(site: site, board: board, threadNum: threadNum) }

        public init(
            key: ThreadKey,
            title: String,
            visitedAt: Date = .now,
            thumbnailPath: String? = nil
        ) {
            self.siteRaw = key.site.rawValue
            self.board = key.board
            self.threadNum = key.threadNum
            self.title = title
            self.visitedAt = visitedAt
            self.thumbnailPath = thumbnailPath
        }
    }

    /// How far the reader got in a thread, and what the watcher last saw.
    ///
    /// Kept for every thread that has been opened, not just favourites, so the
    /// unread divider and scroll restoration work everywhere.
    @Model
    public final class WatchedThreadState {
        #Unique<WatchedThreadState>([\.siteRaw, \.board, \.threadNum])
        #Index<WatchedThreadState>([\.lastPolledAt], [\.siteRaw, \.board, \.threadNum])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var threadNum: Int = 0

        /// Highest post number the reader has seen.
        public var lastReadPostNum: Int = 0
        /// Highest post number the app knows the thread has.
        public var lastKnownMaxNum: Int = 0
        public var lastKnownPostsCount: Int = 0
        public var unreadCount: Int = 0

        /// How many posts the thread held when the reader last left it.
        ///
        /// Unread is the difference between this and what the thread holds now.
        /// Post numbers are site-wide rather than per-thread, so they cannot be
        /// subtracted; counts can. Zero for a thread never opened, which makes
        /// all of it unread, and that is what a favourite added from a board
        /// list is.
        public var readPostsCount: Int = 0

        /// The thread 404s: it was deleted or archived away.
        ///
        /// Not named `isDeleted`: `PersistentModel` already declares that for
        /// its own bookkeeping, and the collision silently shadowed this value.
        public var isThreadDeleted: Bool = false
        public var isClosed: Bool = false
        public var isArchived: Bool = false
        public var lastPolledAt: Date = Date.distantPast
        /// The failure from the last poll, kept so the UI can explain itself.
        public var lastError: String?

        /// Post the list was scrolled to, so reopening lands in the same place.
        public var scrollAnchorPostNum: Int?
        public var scrollAnchorOffset: Double = 0

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public var key: ThreadKey { ThreadKey(site: site, board: board, threadNum: threadNum) }

        public init(key: ThreadKey) {
            self.siteRaw = key.site.rawValue
            self.board = key.board
            self.threadNum = key.threadNum
        }
    }

    /// An unsent post, kept per board and thread.
    ///
    /// Dashchan readers expect a half-written reply to survive leaving the
    /// screen, the app being backgrounded and even a relaunch, so drafts are
    /// stored rather than held in view state.
    @Model
    public final class Draft {
        #Unique<Draft>([\.siteRaw, \.board, \.threadNum])
        #Index<Draft>([\.updatedAt], [\.siteRaw, \.board, \.threadNum])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        /// `0` means a new thread.
        public var threadNum: Int = 0

        public var comment: String = ""
        public var subject: String = ""
        public var name: String = ""
        public var email: String = ""
        public var tags: String = ""
        public var icon: Int?
        public var isSage: Bool = false
        public var isOriginalPoster: Bool = false
        public var updatedAt: Date = Date.distantPast

        @Relationship(deleteRule: .cascade, inverse: \DraftAttachment.draft)
        public var attachments: [DraftAttachment] = []

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public init(board: BoardRef, threadNum: Int) {
            self.siteRaw = board.site.rawValue
            self.board = board.code
            self.threadNum = threadNum
            self.updatedAt = .now
        }

        /// True when there is nothing worth keeping.
        public var isEmpty: Bool {
            comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && subject.isEmpty && attachments.isEmpty
        }
    }

    /// A file staged for an unsent post.
    ///
    /// The bytes live on disk rather than in the database, because a draft may
    /// hold several videos and SwiftData is a poor place for tens of megabytes.
    ///
    /// No site of its own: it belongs to a `Draft`, which has one.
    @Model
    public final class DraftAttachment {
        public var id: UUID = UUID()
        public var fileName: String = ""
        /// Path under Application Support, relative so the container can move.
        public var localRelativePath: String = ""
        public var mimeType: String = ""
        public var order: Int = 0

        // Per-file processing, applied when the post is sent.
        public var appendsUniqueHash: Bool = false
        public var stripsMetadata: Bool = false
        /// JPEG quality percentage, when the file should be re-encoded.
        public var reencodeQuality: Int?
        /// Percentage of the original dimensions, when it should be scaled down.
        public var scalePercent: Int?
        public var renameTo: String?
        public var isSpoiler: Bool = false

        public var draft: Draft?

        public init(fileName: String, localRelativePath: String, mimeType: String, order: Int) {
            self.id = UUID()
            self.fileName = fileName
            self.localRelativePath = localRelativePath
            self.mimeType = mimeType
            self.order = order
        }
    }

    /// A post made from this device.
    ///
    /// Kept so the reader's own posts, and replies to them, can be marked in
    /// any thread; neither site tells a client which posts were its own.
    @Model
    public final class OwnPost {
        #Unique<OwnPost>([\.siteRaw, \.board, \.postNum])
        #Index<OwnPost>([\.siteRaw, \.board, \.threadNum], [\.createdAt])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var threadNum: Int = 0
        public var postNum: Int = 0
        public var createdAt: Date = Date.distantPast

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public init(key: ThreadKey, postNum: Int, createdAt: Date = .now) {
            self.siteRaw = key.site.rawValue
            self.board = key.board
            self.threadNum = key.threadNum
            self.postNum = postNum
            self.createdAt = createdAt
        }
    }

    /// A thread the reader keeps an eye on.
    @Model
    public final class Favorite {
        #Unique<Favorite>([\.siteRaw, \.board, \.threadNum])
        #Index<Favorite>([\.createdAt], [\.siteRaw, \.board, \.threadNum])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var threadNum: Int = 0
        /// Title as the site gives it.
        public var title: String = ""
        /// A name the reader gave it instead.
        public var customTitle: String?
        public var createdAt: Date = Date.distantPast
        public var sortOrder: Int = 0
        /// Whether the watcher polls this thread for new posts.
        public var isWatched: Bool = true
        public var opThumbnailPath: String?

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public var key: ThreadKey { ThreadKey(site: site, board: board, threadNum: threadNum) }

        public init(
            key: ThreadKey,
            title: String,
            createdAt: Date = .now,
            opThumbnailPath: String? = nil
        ) {
            self.siteRaw = key.site.rawValue
            self.board = key.board
            self.threadNum = key.threadNum
            self.title = title
            self.createdAt = createdAt
            self.opThumbnailPath = opThumbnailPath
        }

        /// What to show in a list.
        public var displayTitle: String {
            let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !custom.isEmpty { return custom }
            return title.isEmpty ? "/\(board)/\(threadNum)" : title
        }
    }

    /// A board the reader pinned.
    ///
    /// The site is part of the identity, not decoration: `/b/` exists on both.
    @Model
    public final class FavoriteBoard {
        #Unique<FavoriteBoard>([\.siteRaw, \.board])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var name: String = ""
        public var sortOrder: Int = 0
        public var createdAt: Date = Date.distantPast

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public var ref: BoardRef { BoardRef(site: site, code: board) }

        public init(board: BoardRef, name: String, createdAt: Date = .now) {
            self.siteRaw = board.site.rawValue
            self.board = board.code
            self.name = name
            self.createdAt = createdAt
        }
    }

    /// A thread the reader does not want to see on the board.
    @Model
    public final class HiddenThread {
        #Unique<HiddenThread>([\.siteRaw, \.board, \.threadNum])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var threadNum: Int = 0
        public var title: String = ""
        public var hiddenAt: Date = Date.distantPast

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public var key: ThreadKey { ThreadKey(site: site, board: board, threadNum: threadNum) }

        public init(key: ThreadKey, title: String, hiddenAt: Date = .now) {
            self.siteRaw = key.site.rawValue
            self.board = key.board
            self.threadNum = key.threadNum
            self.title = title
            self.hiddenAt = hiddenAt
        }
    }

    /// A hide made from one post, living only inside its thread.
    @Model
    public final class HiddenPostRule {
        #Index<HiddenPostRule>([\.siteRaw, \.board, \.threadNum])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var threadNum: Int = 0
        /// Which kind of hide this is; see `LocalHideRule`.
        public var kindRaw: String = ""
        public var postNum: Int?
        public var name: String?
        public var similarText: String?
        public var createdAt: Date = Date.distantPast

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public init(key: ThreadKey, rule: LocalHideRule, createdAt: Date = .now) {
            self.siteRaw = key.site.rawValue
            self.board = key.board
            self.threadNum = key.threadNum
            self.createdAt = createdAt

            switch rule {
            case .post(let num):
                kindRaw = "post"
                postNum = num
            case .repliesTree(let num):
                kindRaw = "repliesTree"
                postNum = num
            case .name(let value):
                kindRaw = "name"
                name = value
            case .similar(let text):
                kindRaw = "similar"
                similarText = text
            }
        }

        /// The rule this row represents, or nil when the row is malformed.
        public var rule: LocalHideRule? {
            switch kindRaw {
            case "post": postNum.map { .post(num: $0) }
            case "repliesTree": postNum.map { .repliesTree(num: $0) }
            case "name": name.map { .name($0) }
            case "similar": similarText.map { .similar(to: $0) }
            default: nil
            }
        }
    }

    /// A rule that hides posts across threads.
    @Model
    public final class AutohideRule {
        #Index<AutohideRule>([\.sortOrder])

        public var id: UUID = UUID()
        public var isEnabled: Bool = true
        public var pattern: String = ""
        public var isRegularExpression: Bool = false

        public var matchesSubject: Bool = false
        public var matchesComment: Bool = true
        public var matchesName: Bool = false
        public var matchesFileName: Bool = false

        /// Empty means every board.
        public var boards: [String] = []
        /// Empty means every imageboard, the way `boards` does.
        ///
        /// Deliberately not backfilled to 2ch on upgrade: a rule is not a
        /// record of something the reader did on a site, it is what they want
        /// hidden, and narrowing their spam regex to one imageboard because
        /// they happened to write it before there were two would be a surprise.
        public var sitesRaw: [String] = []
        public var threadNum: Int?
        public var appliesToOriginalPostOnly: Bool = false
        public var appliesToSagedOnly: Bool = false

        public var createdAt: Date = Date.distantPast
        public var sortOrder: Int = 0

        public init(value: AutohideRuleValue, createdAt: Date = .now, sortOrder: Int = 0) {
            self.id = value.id
            self.createdAt = createdAt
            self.sortOrder = sortOrder
            apply(value)
        }

        public func apply(_ value: AutohideRuleValue) {
            isEnabled = value.isEnabled
            pattern = value.pattern
            isRegularExpression = value.isRegularExpression
            matchesSubject = value.matchesSubject
            matchesComment = value.matchesComment
            matchesName = value.matchesName
            matchesFileName = value.matchesFileName
            boards = value.boards.sorted()
            sitesRaw = value.sites.map(\.rawValue).sorted()
            threadNum = value.threadNum
            appliesToOriginalPostOnly = value.appliesToOriginalPostOnly
            appliesToSagedOnly = value.appliesToSagedOnly
        }

        public var value: AutohideRuleValue {
            AutohideRuleValue(
                id: id,
                pattern: pattern,
                isRegularExpression: isRegularExpression,
                matchesSubject: matchesSubject,
                matchesComment: matchesComment,
                matchesName: matchesName,
                matchesFileName: matchesFileName,
                boards: Set(boards),
                sites: Set(sitesRaw.compactMap(Imageboard.init(rawValue:))),
                threadNum: threadNum,
                appliesToOriginalPostOnly: appliesToOriginalPostOnly,
                appliesToSagedOnly: appliesToSagedOnly,
                isEnabled: isEnabled
            )
        }
    }

    /// A thread kept on the device so it can be read without a connection.
    @Model
    public final class SavedThread {
        #Unique<SavedThread>([\.siteRaw, \.board, \.threadNum])
        #Index<SavedThread>([\.savedAt])

        public var siteRaw: String = Imageboard.dvach.rawValue
        public var board: String = ""
        public var threadNum: Int = 0
        public var title: String = ""
        public var savedAt: Date = Date.distantPast
        public var postsCount: Int = 0
        public var filesCount: Int = 0
        /// Folder under Application Support holding the snapshot and its media.
        ///
        /// Stored per row rather than recomputed, which is what lets the folder
        /// naming change without moving anything already on disk.
        public var directoryRelativePath: String = ""
        public var bytesOnDisk: Int = 0
        /// False when only thumbnails were kept.
        public var includesFiles: Bool = false

        public var site: Imageboard {
            get { Imageboard(rawValue: siteRaw) ?? .dvach }
            set { siteRaw = newValue.rawValue }
        }

        public var key: ThreadKey { ThreadKey(site: site, board: board, threadNum: threadNum) }

        public init(
            key: ThreadKey,
            title: String,
            directoryRelativePath: String,
            savedAt: Date = .now
        ) {
            self.siteRaw = key.site.rawValue
            self.board = key.board
            self.threadNum = key.threadNum
            self.title = title
            self.directoryRelativePath = directoryRelativePath
            self.savedAt = savedAt
        }
    }

    /// An imported theme, kept as the decoded value so a later change to the
    /// Dashchan format cannot break themes already installed.
    ///
    /// No site: a theme is the reader's, not a site's.
    @Model
    public final class StoredTheme {
        #Unique<StoredTheme>([\.themeID])

        public var themeID: String = ""
        public var name: String = ""
        public var createdAt: Date = Date.now
        /// The encoded `NeechanTheme`.
        public var payload: Data = Data()

        public init(themeID: String, name: String, payload: Data, createdAt: Date = .now) {
            self.themeID = themeID
            self.name = name
            self.payload = payload
            self.createdAt = createdAt
        }
    }
}

// What the rest of the app sees. Nothing outside this folder names a schema
// version, so a future V3 is a change to these lines and nowhere else.
public typealias HistoryEntry = NeechanSchemaV2.HistoryEntry
public typealias WatchedThreadState = NeechanSchemaV2.WatchedThreadState
public typealias Draft = NeechanSchemaV2.Draft
public typealias DraftAttachment = NeechanSchemaV2.DraftAttachment
public typealias OwnPost = NeechanSchemaV2.OwnPost
public typealias Favorite = NeechanSchemaV2.Favorite
public typealias FavoriteBoard = NeechanSchemaV2.FavoriteBoard
public typealias HiddenThread = NeechanSchemaV2.HiddenThread
public typealias HiddenPostRule = NeechanSchemaV2.HiddenPostRule
public typealias AutohideRule = NeechanSchemaV2.AutohideRule
public typealias SavedThread = NeechanSchemaV2.SavedThread
public typealias StoredTheme = NeechanSchemaV2.StoredTheme
