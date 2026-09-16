import Foundation
import SwiftData

/// A thread the reader keeps an eye on.
@Model
public final class Favorite {
    #Unique<Favorite>([\.board, \.threadNum])
    #Index<Favorite>([\.createdAt], [\.board, \.threadNum])

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

    public init(
        board: String,
        threadNum: Int,
        title: String,
        createdAt: Date = .now,
        opThumbnailPath: String? = nil
    ) {
        self.board = board
        self.threadNum = threadNum
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
