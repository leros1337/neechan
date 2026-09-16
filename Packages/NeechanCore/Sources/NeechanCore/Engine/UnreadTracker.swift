import Foundation
import NeechanSettings

/// How far a reader has got in a thread.
///
/// Holds only a post number, not a set of read posts: threads are append-only,
/// so one high-water mark says everything, and it survives posts being deleted
/// from the middle.
public struct UnreadTracker: Sendable, Equatable {
    /// Highest post number the reader has seen.
    public private(set) var lastReadPostNum: Int
    public var mode: UnreadMarkerMode

    public init(lastReadPostNum: Int, mode: UnreadMarkerMode) {
        self.lastReadPostNum = lastReadPostNum
        self.mode = mode
    }

    /// The post the "new posts" divider goes above, if there is one.
    public func firstUnreadPostNum(in postNums: [Int]) -> Int? {
        guard mode != .never else { return nil }
        return postNums.first { $0 > lastReadPostNum }
    }

    /// How many posts the reader has not seen. Counted even with markers off,
    /// because the favourites badge uses it.
    public func unreadCount(in postNums: [Int]) -> Int {
        postNums.count { $0 > lastReadPostNum }
    }

    public func showsDivider(before postNum: Int, in postNums: [Int]) -> Bool {
        firstUnreadPostNum(in: postNums) == postNum
    }

    /// Records that a post has been on screen long enough to count as read.
    ///
    /// Ignored in manual mode, where only an explicit action marks anything read.
    public mutating func markSeen(_ postNum: Int) {
        guard mode == .automatic else { return }
        lastReadPostNum = max(lastReadPostNum, postNum)
    }

    /// Marks everything up to `postNum` read, whatever the mode.
    public mutating func markAllRead(upTo postNum: Int) {
        lastReadPostNum = max(lastReadPostNum, postNum)
    }
}
