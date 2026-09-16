import Foundation
import SwiftData

/// How far the reader got in a thread, and what the watcher last saw.
///
/// Kept for every thread that has been opened, not just favourites, so the
/// unread divider and scroll restoration work everywhere.
@Model
public final class WatchedThreadState {
    #Unique<WatchedThreadState>([\.board, \.threadNum])
    #Index<WatchedThreadState>([\.lastPolledAt], [\.board, \.threadNum])

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
    /// subtracted; counts can. Zero for a thread never opened, which makes all
    /// of it unread, and that is what a favourite added from a board list is.
    public var readPostsCount: Int = 0

    /// The thread 404s: it was deleted or archived away.
    ///
    /// Not named `isDeleted`: `PersistentModel` already declares that for its
    /// own bookkeeping, and the collision silently shadowed this value.
    public var isThreadDeleted: Bool = false
    public var isClosed: Bool = false
    public var isArchived: Bool = false
    public var lastPolledAt: Date = Date.distantPast
    /// The failure from the last poll, kept so the UI can explain itself.
    public var lastError: String?

    /// Post the list was scrolled to, so reopening lands in the same place.
    public var scrollAnchorPostNum: Int?
    public var scrollAnchorOffset: Double = 0

    public init(board: String, threadNum: Int) {
        self.board = board
        self.threadNum = threadNum
    }
}
