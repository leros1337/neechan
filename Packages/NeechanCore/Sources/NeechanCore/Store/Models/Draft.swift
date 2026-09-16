import Foundation
import SwiftData

/// An unsent post, kept per board and thread.
///
/// Dashchan readers expect a half-written reply to survive leaving the screen,
/// the app being backgrounded and even a relaunch, so drafts are stored rather
/// than held in view state.
@Model
public final class Draft {
    #Unique<Draft>([\.board, \.threadNum])
    #Index<Draft>([\.updatedAt], [\.board, \.threadNum])

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

    public init(board: String, threadNum: Int) {
        self.board = board
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
/// The bytes live on disk rather than in the database, because a draft may hold
/// several videos and SwiftData is a poor place for tens of megabytes.
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

    public init(
        fileName: String,
        localRelativePath: String,
        mimeType: String,
        order: Int
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.localRelativePath = localRelativePath
        self.mimeType = mimeType
        self.order = order
    }
}
