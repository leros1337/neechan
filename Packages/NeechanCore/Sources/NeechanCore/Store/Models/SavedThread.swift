import Foundation
import SwiftData

/// A thread kept on the device so it can be read without a connection.
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
    /// Folder under Application Support holding the snapshot and its media.
    public var directoryRelativePath: String = ""
    public var bytesOnDisk: Int = 0
    /// False when only thumbnails were kept.
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
