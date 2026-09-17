import Foundation
import NeechanAPI

/// Somewhere in the app the user can be taken to.
///
/// Every case names the imageboard, because a pasted link carries its own and
/// it need not be the one selected.
public enum NavigationTarget: Sendable, Hashable {
    case board(BoardRef)
    case thread(ThreadKey)
    case threadAtPost(ThreadKey, postNum: Int)
    /// A post whose thread is not known yet; resolved by looking it up.
    case post(BoardRef, num: Int)

    /// Which imageboard this destination is on.
    public var site: Imageboard {
        switch self {
        case .board(let board), .post(let board, _): board.site
        case .thread(let key), .threadAtPost(let key, _): key.site
        }
    }

    public var board: String {
        switch self {
        case .board(let board), .post(let board, _): board.code
        case .thread(let key), .threadAtPost(let key, _): key.board
        }
    }
}

/// Turns whatever the user types in the search box into a destination.
///
/// Dashchan's drawer accepts a board code, a post number or a link in the same
/// field, and readers expect that; anything it cannot resolve is left to be
/// treated as a search term.
public enum NavigationQueryParser {
    /// - Parameters:
    ///   - site: the imageboard being read, used for input that does not name
    ///     one of its own.
    ///   - currentBoard: the board being read, so a bare post number can be
    ///     resolved. Nil when there is no board context.
    public static func parse(
        _ input: String,
        site: Imageboard,
        currentBoard: String? = nil
    ) -> NavigationTarget? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let target = parseLink(text, site: site) { return target }
        if let target = parsePostNumber(text, site: site, currentBoard: currentBoard) {
            return target
        }
        if let board = BoardCode.normalized(text, for: site) {
            return .board(BoardRef(site: site, code: board))
        }
        return nil
    }

    // MARK: Pieces

    /// The imageboard a host belongs to, or nil when it is nobody's.
    static func site(forHost host: String) -> Imageboard? {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return Imageboard.allCases.first { $0.linkHosts.contains(bare) }
    }

    private static func parseLink(_ text: String, site: Imageboard) -> NavigationTarget? {
        // Accept a bare host as well as a full URL, the way a browser would.
        let candidate = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: candidate) else { return parsePath(text, site: site) }

        if let host = url.host()?.lowercased() {
            // A pasted link goes to the imageboard its host names, whatever is
            // selected: pasting a 4chan thread while reading 2ch should open
            // the thread, not nothing.
            guard let linked = Self.site(forHost: host) else {
                // A path-only input has no host and is handled below; a foreign
                // host is not ours to open.
                return text.hasPrefix("/") ? parsePath(text, site: site) : nil
            }
            return parsePath(url.path(), site: linked, fragment: url.fragment())
        }
        return parsePath(text, site: site)
    }

    private static func parsePath(
        _ path: String,
        site: Imageboard,
        fragment: String? = nil
    ) -> NavigationTarget? {
        var path = path
        var anchor = fragment
        if anchor == nil, let hash = path.firstIndex(of: "#") {
            anchor = String(path[path.index(after: hash)...])
            path = String(path[..<hash])
        }

        let segments = path.split(separator: "/").map(String.init)
        guard let rawBoard = segments.first else { return nil }

        // A path-only input names no host, so it may be either site's. The two
        // thread grammars are distinct enough to tell apart — 2ch never writes
        // `thread`, 4chan never writes `res` — which is what lets a pasted
        // `/g/thread/123` work while reading 2ch.
        let resolved: Imageboard = if segments.count >= 2 {
            switch segments[1] {
            case "thread": .fourchan
            case "res": .dvach
            default: site
            }
        } else {
            site
        }
        guard let board = BoardCode.normalized(rawBoard, for: resolved) else { return nil }
        let ref = BoardRef(site: resolved, code: board)

        // 2ch: /{board}/res/{num}.html   4chan: /{board}/thread/{num}[/{slug}]
        if segments.count >= 3, segments[1] == "res" || segments[1] == "thread" {
            let numberPart = segments[2].prefix { $0.isNumber }
            guard let threadNum = Int(numberPart) else { return nil }
            let key = ThreadKey(site: resolved, board: board, threadNum: threadNum)
            // 4chan anchors a post as `#p456`, 2ch as `#456`.
            if let anchor,
               let postNum = Int(anchor.drop { !$0.isNumber }.prefix { $0.isNumber }),
               postNum != threadNum {
                return .threadAtPost(key, postNum: postNum)
            }
            return .thread(key)
        }

        // /{board}/ , /{board}/index.html , /{board}/catalog.html , /{board}/catalog
        if segments.count == 1 || ["index", "catalog", "catalog_num"].contains(
            segments[1].split(separator: ".").first.map(String.init) ?? ""
        ) {
            return .board(ref)
        }
        return nil
    }

    private static func parsePostNumber(
        _ text: String,
        site: Imageboard,
        currentBoard: String?
    ) -> NavigationTarget? {
        let digits = text.hasPrefix(">>") ? String(text.dropFirst(2)) : text
        guard digits.allSatisfy(\.isNumber), !digits.isEmpty, let num = Int(digits) else {
            return nil
        }
        // On a site with an all-digit board code, a very short number is far
        // more likely to be that board than a post: 4chan's `/3/` would
        // otherwise be unreachable by typing it.
        if site.allowsNumericBoardCodes, digits.count <= 2,
           let board = BoardCode.normalized(digits, for: site) {
            return .board(BoardRef(site: site, code: board))
        }
        guard let currentBoard, BoardCode.normalized(currentBoard, for: site) != nil else {
            return nil
        }
        return .post(BoardRef(site: site, code: currentBoard), num: num)
    }
}
