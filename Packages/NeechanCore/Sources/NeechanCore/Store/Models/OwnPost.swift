import Foundation
import SwiftData

/// A post made from this device.
///
/// Kept so the reader's own posts, and replies to them, can be marked in any
/// thread; 2ch itself does not tell a client which posts were its own.
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
