import Foundation
import NeechanAPI
import NeechanSettings

/// What one watcher banner says, settled apart from posting it.
///
/// Kept clear of `UserNotifications` because the notification centre traps in
/// a process with no app bundle, which is how the package tests run, and which
/// banner a poll deserves is the part worth testing.
public struct WatcherNotification: Sendable, Equatable {
    public let title: String
    /// New posts to mention, or nil to leave them out.
    public let newPosts: Int?
    /// Answers to the reader to mention, or nil.
    public let replies: Int?
    public let payload: NotificationPayload

    /// The banner one poll result deserves under `setting`, or nil for none.
    ///
    /// - Parameter title: the thread's name as the reader keeps it; nil falls
    ///   back to its address.
    public init?(
        for result: ThreadWatcher.Result,
        title: String?,
        setting: WatcherNotificationSetting
    ) {
        switch setting {
        case .off:
            return nil
        case .repliesOnly:
            guard result.hasReplies else { return nil }
            newPosts = nil
        case .allNewPosts:
            guard result.hasNews else { return nil }
            newPosts = result.newPostCount
        }
        replies = result.hasReplies ? result.replies.count : nil
        self.title = title ?? "/\(result.key.board)/\(result.key.threadNum)"
        // Landing on the first answer is what the reader came for; a plain
        // count has no post worth landing on, so the thread opens where they
        // left it.
        payload = NotificationPayload(key: result.key, postNum: result.replies.first)
    }

    /// The banner's text, in the language the reader picked.
    public var body: String {
        var parts: [String] = []
        if let newPosts {
            parts.append(
                String(
                    localized: "\(newPosts) new posts",
                    bundle: .module.forAppLanguage(),
                    locale: AppLocale.current
                )
            )
        }
        if let replies {
            parts.append(
                String(
                    localized: "\(replies) replies to you",
                    bundle: .module.forAppLanguage(),
                    locale: AppLocale.current
                )
            )
        }
        return parts.joined(separator: " · ")
    }
}

/// What a banner carries so tapping it can open the right place.
public struct NotificationPayload: Sendable, Hashable {
    public let key: ThreadKey
    /// The post to land on, when there is one worth landing on.
    public let postNum: Int?

    public init(key: ThreadKey, postNum: Int?) {
        self.key = key
        self.postNum = postNum
    }

    /// The names banners have always been delivered under, so one posted by an
    /// older build still opens its thread.
    private enum Field {
        static let site = "site"
        static let board = "board"
        static let threadNum = "threadNum"
        static let postNum = "postNum"
    }

    public var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            Field.site: key.site.rawValue,
            Field.board: key.board,
            Field.threadNum: key.threadNum,
        ]
        if let postNum { info[Field.postNum] = postNum }
        return info
    }

    /// Reads a delivered banner back; nil when it does not name a thread.
    public init?(userInfo: [AnyHashable: Any]) {
        guard
            let siteRaw = userInfo[Field.site] as? String,
            let site = Imageboard(rawValue: siteRaw),
            let board = userInfo[Field.board] as? String,
            let threadNum = userInfo[Field.threadNum] as? Int
        else { return nil }
        self.init(
            key: ThreadKey(site: site, board: board, threadNum: threadNum),
            postNum: userInfo[Field.postNum] as? Int
        )
    }

    public var target: NavigationTarget {
        postNum.map { .threadAtPost(key, postNum: $0) } ?? .thread(key)
    }
}
