import Foundation

/// Builds the canonical web addresses for boards, threads and posts.
///
/// These are the links the site itself uses, so anything shared out of the app
/// opens correctly in a browser or in another client.
public enum DvachLinks {
    /// `https://2ch.org/b/`
    public static func board(_ board: String, on domain: DvachDomain) -> URL? {
        domain.url(forPath: "/\(board)/")
    }

    /// `https://2ch.org/b/res/123.html`
    public static func thread(
        board: String,
        threadNum: Int,
        on domain: DvachDomain
    ) -> URL? {
        domain.url(forPath: "/\(board)/res/\(threadNum).html")
    }

    /// `https://2ch.org/b/res/123.html#456`
    ///
    /// The anchor is what makes a shared link land on the post rather than at
    /// the top of the thread.
    public static func post(
        board: String,
        threadNum: Int,
        postNum: Int,
        on domain: DvachDomain
    ) -> URL? {
        guard let base = thread(board: board, threadNum: threadNum, on: domain) else { return nil }
        // A post that opens its own thread needs no anchor.
        guard postNum != threadNum else { return base }
        return URL(string: "\(base.absoluteString)#\(postNum)")
    }
}
