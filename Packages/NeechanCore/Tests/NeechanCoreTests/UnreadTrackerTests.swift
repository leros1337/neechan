import Foundation
import Testing
@testable import NeechanCore
import NeechanSettings

@Suite("Unread tracker")
struct UnreadTrackerTests {
    /// Everything is unread, and that is exactly why there is no divider: a
    /// line above the opening post separates the thread from nothing.
    @Test("a thread never opened has everything unread and no divider")
    func neverOpened() {
        let tracker = UnreadTracker(lastReadPostNum: 0, mode: .automatic)
        #expect(tracker.firstUnreadPostNum(in: [1, 2, 3]) == nil)
        #expect(tracker.showsDivider(before: 1, in: [1, 2, 3]) == false)
        #expect(tracker.unreadCount(in: [1, 2, 3]) == 3)
    }

    /// The same rule where the reader did read something, but every post they
    /// read has since been deleted: there is still nothing above the line.
    @Test("nothing read that still exists means no divider")
    func everythingReadWasDeleted() {
        let tracker = UnreadTracker(lastReadPostNum: 2, mode: .automatic)
        #expect(tracker.firstUnreadPostNum(in: [7, 8]) == nil)
        #expect(tracker.unreadCount(in: [7, 8]) == 2)
    }

    @Test("posts up to the last read one are read")
    func partiallyRead() {
        let tracker = UnreadTracker(lastReadPostNum: 2, mode: .automatic)
        #expect(tracker.firstUnreadPostNum(in: [1, 2, 3, 4]) == 3)
        #expect(tracker.unreadCount(in: [1, 2, 3, 4]) == 2)
    }

    @Test("a fully read thread has no divider and no count")
    func fullyRead() {
        let tracker = UnreadTracker(lastReadPostNum: 4, mode: .automatic)
        #expect(tracker.firstUnreadPostNum(in: [1, 2, 3, 4]) == nil)
        #expect(tracker.unreadCount(in: [1, 2, 3, 4]) == 0)
    }

    @Test("the divider sits before the first unread post")
    func dividerPosition() {
        let tracker = UnreadTracker(lastReadPostNum: 2, mode: .automatic)
        #expect(tracker.showsDivider(before: 3, in: [1, 2, 3, 4]))
        #expect(tracker.showsDivider(before: 4, in: [1, 2, 3, 4]) == false)
        #expect(tracker.showsDivider(before: 1, in: [1, 2, 3, 4]) == false)
    }

    @Test("turning markers off removes the divider entirely")
    func neverMode() {
        let tracker = UnreadTracker(lastReadPostNum: 2, mode: .never)
        #expect(tracker.firstUnreadPostNum(in: [1, 2, 3, 4]) == nil)
        #expect(tracker.showsDivider(before: 3, in: [1, 2, 3, 4]) == false)
        // The count still matters: the watcher badge uses it.
        #expect(tracker.unreadCount(in: [1, 2, 3, 4]) == 2)
    }

    @Test("automatic mode marks a post read once it has been seen")
    func automaticMarksSeen() {
        var tracker = UnreadTracker(lastReadPostNum: 1, mode: .automatic)
        tracker.markSeen(3)
        #expect(tracker.lastReadPostNum == 3)
    }

    @Test("manual mode ignores what has merely scrolled past")
    func manualIgnoresSeen() {
        var tracker = UnreadTracker(lastReadPostNum: 1, mode: .manual)
        tracker.markSeen(3)
        #expect(tracker.lastReadPostNum == 1)

        tracker.markAllRead(upTo: 4)
        #expect(tracker.lastReadPostNum == 4)
    }

    @Test("reading never goes backwards")
    func neverRegresses() {
        var tracker = UnreadTracker(lastReadPostNum: 5, mode: .automatic)
        tracker.markSeen(2)
        #expect(tracker.lastReadPostNum == 5)
    }

    @Test("an empty thread has nothing unread")
    func emptyThread() {
        let tracker = UnreadTracker(lastReadPostNum: 0, mode: .automatic)
        #expect(tracker.firstUnreadPostNum(in: []) == nil)
        #expect(tracker.unreadCount(in: []) == 0)
    }

    // MARK: Since the last visit

    @Test("coming back finds the posts that arrived since the last visit")
    func postsSinceLastVisit() {
        let tracker = UnreadTracker(lastReadPostNum: 2, mode: .automatic)
        #expect(tracker.postsSinceLastVisit(in: [1, 2, 3, 4]) == [3, 4])
    }

    /// Every post would count, and "300 new posts" on a thread nobody has
    /// opened before says nothing.
    @Test("a thread opened for the first time has nothing since a last visit")
    func firstVisitHasNothingSince() {
        let tracker = UnreadTracker(lastReadPostNum: 0, mode: .automatic)
        #expect(tracker.postsSinceLastVisit(in: [1, 2, 3]).isEmpty)
    }

    @Test("a thread with nothing new since the last visit has nothing since it")
    func nothingNewSinceLastVisit() {
        let tracker = UnreadTracker(lastReadPostNum: 4, mode: .automatic)
        #expect(tracker.postsSinceLastVisit(in: [1, 2, 3, 4]).isEmpty)
    }

    /// The divider is a setting; what arrived while the reader was away is a
    /// fact either way.
    @Test("posts since the last visit are found with the divider turned off")
    func postsSinceLastVisitIgnoreMarkerMode() {
        let tracker = UnreadTracker(lastReadPostNum: 2, mode: .never)
        #expect(tracker.firstUnreadPostNum(in: [1, 2, 3]) == nil)
        #expect(tracker.postsSinceLastVisit(in: [1, 2, 3]) == [3])
    }

    @Test("posts deleted from the middle do not inflate the count")
    func handlesGaps() {
        // 2 and 3 were deleted; only 4 and 5 are genuinely unread.
        let tracker = UnreadTracker(lastReadPostNum: 1, mode: .automatic)
        #expect(tracker.unreadCount(in: [1, 4, 5]) == 2)
        #expect(tracker.firstUnreadPostNum(in: [1, 4, 5]) == 4)
    }
}
