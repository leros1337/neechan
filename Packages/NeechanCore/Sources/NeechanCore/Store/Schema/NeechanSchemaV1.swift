import Foundation
import SwiftData

/// The first persisted schema, frozen.
///
/// Versioned from the very first release so that a later change has somewhere
/// to migrate from; SwiftData cannot retrofit a version onto an unversioned
/// store without losing it.
///
/// The models are nested here rather than shared with V2 because a migration
/// stage compares two `VersionedSchema`s, and two versions naming the same live
/// types are the same version — which is the configuration that crashed the app
/// on launch the first time a stage was written. Nesting makes them different
/// types; SwiftData still names the entity after the unqualified class name, so
/// `NeechanSchemaV1.Favorite` and `NeechanSchemaV2.Favorite` are two shapes of
/// one entity called `Favorite`, which is exactly what a migration needs.
///
/// Nothing outside migration should use these. They are the old shape, kept
/// only so the store can be read out of it.
public enum NeechanSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

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

    @Model
    public final class HistoryEntry {
        #Unique<HistoryEntry>([\.board, \.threadNum])
        #Index<HistoryEntry>([\.visitedAt], [\.board, \.threadNum])

        public var board: String = ""
        public var threadNum: Int = 0
        public var title: String = ""
        public var visitedAt: Date = Date.distantPast
        public var thumbnailPath: String?

        public init(board: String, threadNum: Int, title: String, visitedAt: Date = .now) {
            self.board = board
            self.threadNum = threadNum
            self.title = title
            self.visitedAt = visitedAt
        }
    }

    @Model
    public final class WatchedThreadState {
        #Unique<WatchedThreadState>([\.board, \.threadNum])
        #Index<WatchedThreadState>([\.lastPolledAt], [\.board, \.threadNum])

        public var board: String = ""
        public var threadNum: Int = 0
        public var lastReadPostNum: Int = 0
        public var lastKnownMaxNum: Int = 0
        public var lastKnownPostsCount: Int = 0
        public var unreadCount: Int = 0
        public var readPostsCount: Int = 0
        public var isThreadDeleted: Bool = false
        public var isClosed: Bool = false
        public var isArchived: Bool = false
        public var lastPolledAt: Date = Date.distantPast
        public var lastError: String?
        public var scrollAnchorPostNum: Int?
        public var scrollAnchorOffset: Double = 0

        public init(board: String, threadNum: Int) {
            self.board = board
            self.threadNum = threadNum
        }
    }

    @Model
    public final class Draft {
        #Unique<Draft>([\.board, \.threadNum])
        #Index<Draft>([\.updatedAt], [\.board, \.threadNum])

        public var board: String = ""
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

        public init(board: String, threadNum: Int) {
            self.board = board
            self.threadNum = threadNum
            self.updatedAt = .now
        }
    }

    @Model
    public final class DraftAttachment {
        public var id: UUID = UUID()
        public var fileName: String = ""
        public var localRelativePath: String = ""
        public var mimeType: String = ""
        public var order: Int = 0
        public var appendsUniqueHash: Bool = false
        public var stripsMetadata: Bool = false
        public var reencodeQuality: Int?
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

    @Model
    public final class OwnPost {
        #Unique<OwnPost>([\.board, \.postNum])
        #Index<OwnPost>([\.board, \.threadNum], [\.createdAt])

        public var board: String = ""
        public var threadNum: Int = 0
        public var postNum: Int = 0
        public var createdAt: Date = Date.distantPast

        public init(board: String, threadNum: Int, postNum: Int, createdAt: Date = .now) {
            self.board = board
            self.threadNum = threadNum
            self.postNum = postNum
            self.createdAt = createdAt
        }
    }

    @Model
    public final class Favorite {
        #Unique<Favorite>([\.board, \.threadNum])
        #Index<Favorite>([\.createdAt], [\.board, \.threadNum])

        public var board: String = ""
        public var threadNum: Int = 0
        public var title: String = ""
        public var customTitle: String?
        public var createdAt: Date = Date.distantPast
        public var sortOrder: Int = 0
        public var isWatched: Bool = true
        public var opThumbnailPath: String?

        public init(board: String, threadNum: Int, title: String, createdAt: Date = .now) {
            self.board = board
            self.threadNum = threadNum
            self.title = title
            self.createdAt = createdAt
        }
    }

    @Model
    public final class FavoriteBoard {
        #Unique<FavoriteBoard>([\.board])

        public var board: String = ""
        public var name: String = ""
        public var sortOrder: Int = 0
        public var createdAt: Date = Date.distantPast

        public init(board: String, name: String, createdAt: Date = .now) {
            self.board = board
            self.name = name
            self.createdAt = createdAt
        }
    }

    @Model
    public final class HiddenThread {
        #Unique<HiddenThread>([\.board, \.threadNum])

        public var board: String = ""
        public var threadNum: Int = 0
        public var title: String = ""
        public var hiddenAt: Date = Date.distantPast

        public init(board: String, threadNum: Int, title: String, hiddenAt: Date = .now) {
            self.board = board
            self.threadNum = threadNum
            self.title = title
            self.hiddenAt = hiddenAt
        }
    }

    @Model
    public final class HiddenPostRule {
        #Index<HiddenPostRule>([\.board, \.threadNum])

        public var board: String = ""
        public var threadNum: Int = 0
        public var kindRaw: String = ""
        public var postNum: Int?
        public var name: String?
        public var similarText: String?
        public var createdAt: Date = Date.distantPast

        public init(board: String, threadNum: Int, kindRaw: String, createdAt: Date = .now) {
            self.board = board
            self.threadNum = threadNum
            self.kindRaw = kindRaw
            self.createdAt = createdAt
        }
    }

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
        public var boards: [String] = []
        public var threadNum: Int?
        public var appliesToOriginalPostOnly: Bool = false
        public var appliesToSagedOnly: Bool = false
        public var createdAt: Date = Date.distantPast
        public var sortOrder: Int = 0

        public init(pattern: String, createdAt: Date = .now, sortOrder: Int = 0) {
            self.id = UUID()
            self.pattern = pattern
            self.createdAt = createdAt
            self.sortOrder = sortOrder
        }
    }

    @Model
    public final class SavedThread {
        #Unique<SavedThread>([\.board, \.threadNum])
        #Index<SavedThread>([\.savedAt])

        public var board: String = ""
        public var threadNum: Int = 0
        public var title: String = ""
        public var savedAt: Date = Date.distantPast
        public var postsCount: Int = 0
        public var filesCount: Int = 0
        public var directoryRelativePath: String = ""
        public var bytesOnDisk: Int = 0
        public var includesFiles: Bool = false

        public init(
            board: String,
            threadNum: Int,
            title: String,
            directoryRelativePath: String,
            savedAt: Date = .now
        ) {
            self.board = board
            self.threadNum = threadNum
            self.title = title
            self.directoryRelativePath = directoryRelativePath
            self.savedAt = savedAt
        }
    }

    @Model
    public final class StoredTheme {
        #Unique<StoredTheme>([\.themeID])

        public var themeID: String = ""
        public var name: String = ""
        public var createdAt: Date = Date.now
        public var payload: Data = Data()

        public init(themeID: String, name: String, payload: Data, createdAt: Date = .now) {
            self.themeID = themeID
            self.name = name
            self.payload = payload
            self.createdAt = createdAt
        }
    }
}
