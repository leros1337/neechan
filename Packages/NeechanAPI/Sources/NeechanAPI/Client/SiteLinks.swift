import Foundation

/// Links to the readable site, for sharing and for opening in a browser.
///
/// Replaces the 2ch-only `DvachLinks`: the two sites write a thread's address
/// differently (`/b/res/123.html#456` against `/b/thread/123#p456`), and 4chan
/// serves its readable pages from a host of its own.
public enum SiteLinks {
    public static func board(_ board: String, on selection: SiteSelection) -> URL? {
        let web = selection.endpoints.web
        return URL(string: "/\(board)/", relativeTo: web)?.absoluteURL
    }

    public static func thread(
        board: String,
        threadNum: Int,
        on selection: SiteSelection
    ) -> URL? {
        let web = selection.endpoints.web
        let path = switch selection.site {
        case .dvach: "/\(board)/res/\(threadNum).html"
        case .fourchan: "/\(board)/thread/\(threadNum)"
        }
        return URL(string: path, relativeTo: web)?.absoluteURL
    }

    /// A link to one post inside its thread.
    ///
    /// The original post needs no fragment: the thread's own address already
    /// opens there, and a reader pasting it elsewhere gets a cleaner link.
    public static func post(
        board: String,
        threadNum: Int,
        postNum: Int,
        on selection: SiteSelection
    ) -> URL? {
        guard let thread = thread(board: board, threadNum: threadNum, on: selection) else {
            return nil
        }
        guard postNum != threadNum else { return thread }
        let fragment = switch selection.site {
        case .dvach: "#\(postNum)"
        case .fourchan: "#p\(postNum)"
        }
        return URL(string: thread.absoluteString + fragment)
    }

    /// The site's own report form, for a site that answers a report with a page
    /// rather than with an API.
    ///
    /// Nil on 2ch, which is reported through ``ReportService`` instead — and
    /// nil is the right answer rather than an oversight, because a caller that
    /// gets one is being told to take the other route.
    ///
    /// Built on `endpoints.posting` and not `endpoints.web`: the form lives
    /// beside the posting script, on `sys.4chan.org`, and the readable host
    /// does not serve it.
    public static func report(
        board: String,
        postNum: Int,
        on selection: SiteSelection
    ) -> URL? {
        guard case .web = selection.capabilities.reporting else { return nil }
        // Built as a string against the host, the way every other link here is,
        // rather than through `appending(path:)` — that escapes what it is
        // given, and the code has already been through `escapeBoardCode`.
        let path = "/\(escapeBoardCode(board))/imgboard.php?mode=report&no=\(postNum)"
        return URL(string: path, relativeTo: selection.endpoints.posting)?.absoluteURL
    }
}
