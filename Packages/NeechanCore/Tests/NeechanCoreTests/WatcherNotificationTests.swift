import Foundation
import NeechanAPI
import NeechanSettings
import Testing
@testable import NeechanCore

@Suite("Watcher notifications")
struct WatcherNotificationTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 1)

    private func result(newPosts: Int, replies: [Int] = []) -> ThreadWatcher.Result {
        ThreadWatcher.Result(key: key, newPostCount: newPosts, isDeleted: false, replies: replies)
    }

    @Test("nothing is said when notifications are off")
    func offIsSilent() {
        let note = WatcherNotification(for: result(newPosts: 3, replies: [7]), title: "Тред", setting: .off)
        #expect(note == nil)
    }

    /// The bug this replaces: "Replies to me" used to fire for every post.
    @Test("replies only stays quiet about posts that answer nobody")
    func repliesOnlyIgnoresOtherPosts() {
        let note = WatcherNotification(for: result(newPosts: 3), title: "Тред", setting: .repliesOnly)
        #expect(note == nil)
    }

    @Test("replies only speaks of the replies and lands on the first")
    func repliesOnlyNamesReplies() {
        let note = WatcherNotification(
            for: result(newPosts: 3, replies: [7, 9]), title: "Тред", setting: .repliesOnly
        )
        #expect(note?.newPosts == nil)
        #expect(note?.replies == 2)
        #expect(note?.payload == NotificationPayload(key: key, postNum: 7))
    }

    @Test("all new posts counts them and opens the thread where the reader left it")
    func allNewPostsCounts() {
        let note = WatcherNotification(for: result(newPosts: 3), title: "Тред", setting: .allNewPosts)
        #expect(note?.newPosts == 3)
        #expect(note?.replies == nil)
        #expect(note?.payload == NotificationPayload(key: key, postNum: nil))
    }

    @Test("all new posts mentions a reply among them")
    func allNewPostsMentionsReplies() {
        let note = WatcherNotification(
            for: result(newPosts: 3, replies: [7]), title: "Тред", setting: .allNewPosts
        )
        #expect(note?.newPosts == 3)
        #expect(note?.replies == 1)
        #expect(note?.payload.postNum == 7)
    }

    @Test("a quiet thread gets no notification")
    func quietThreadIsSilent() {
        let note = WatcherNotification(for: result(newPosts: 0), title: "Тред", setting: .allNewPosts)
        #expect(note == nil)
    }

    @Test("a thread with no known title is named by its address")
    func fallsBackToAddress() {
        let note = WatcherNotification(for: result(newPosts: 1), title: nil, setting: .allNewPosts)
        #expect(note?.title == "/b/1")
    }
}

@Suite("Notification payload")
struct NotificationPayloadTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 1)

    @Test("a payload survives the trip through userInfo", arguments: [7, nil] as [Int?])
    func roundTrips(postNum: Int?) {
        let payload = NotificationPayload(key: key, postNum: postNum)
        #expect(NotificationPayload(userInfo: payload.userInfo) == payload)
    }

    @Test("a reply opens the thread on that post")
    func replyTargetsPost() {
        #expect(NotificationPayload(key: key, postNum: 7).target == .threadAtPost(key, postNum: 7))
    }

    @Test("a count opens the thread itself")
    func countTargetsThread() {
        #expect(NotificationPayload(key: key, postNum: nil).target == .thread(key))
    }

    /// Banners delivered by an older build carry no post number and are still
    /// sitting in Notification Centre after the update.
    @Test("a banner from an older build still opens its thread")
    func readsOlderBanner() {
        let userInfo: [AnyHashable: Any] = ["site": "dvach", "board": "b", "threadNum": 1]
        #expect(NotificationPayload(userInfo: userInfo)?.target == .thread(key))
    }

    @Test("a payload missing its thread is refused")
    func refusesIncomplete() {
        #expect(NotificationPayload(userInfo: ["site": "dvach", "board": "b"]) == nil)
        #expect(NotificationPayload(userInfo: ["site": "nowhere", "board": "b", "threadNum": 1]) == nil)
        #expect(NotificationPayload(userInfo: [:]) == nil)
    }
}
