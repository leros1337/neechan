import Foundation
import SwiftData

/// A thread the reader opened.
@Model
public final class HistoryEntry {
    #Unique<HistoryEntry>([\.board, \.threadNum])
    #Index<HistoryEntry>([\.visitedAt], [\.board, \.threadNum])

    public var board: String = ""
    public var threadNum: Int = 0
    public var title: String = ""
    public var visitedAt: Date = Date.distantPast
    /// Server-relative path to the thread's first thumbnail.
    public var thumbnailPath: String?

    public init(
        board: String,
        threadNum: Int,
        title: String,
        visitedAt: Date = .now,
        thumbnailPath: String? = nil
    ) {
        self.board = board
        self.threadNum = threadNum
        self.title = title
        self.visitedAt = visitedAt
        self.thumbnailPath = thumbnailPath
    }
}
