import Foundation
import NeechanAPI

/// Somewhere in the app the user can be taken to.
public enum NavigationTarget: Sendable, Hashable {
    case board(board: String)
    case thread(board: String, threadNum: Int)
    case threadAtPost(board: String, threadNum: Int, postNum: Int)
    /// A post whose thread is not known yet; resolved by looking it up.
    case post(board: String, num: Int)
}

/// Turns whatever the user types in the search box into a destination.
///
/// Dashchan's drawer accepts a board code, a post number or a link in the same
/// field, and readers expect that; anything it cannot resolve is left to be
/// treated as a search term.
public enum NavigationQueryParser {
    private static let knownHosts: Set<String> = ["2ch.org", "2ch.life", "2ch.hk", "2ch.su", "2ch.pm"]

    /// - Parameter currentBoard: the board being read, so a bare post number
    ///   can be resolved. Nil when there is no board context.
    public static func parse(_ input: String, currentBoard: String? = nil) -> NavigationTarget? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let target = parseLink(text) { return target }
        if let target = parsePostNumber(text, currentBoard: currentBoard) { return target }
        if let board = parseBoardCode(text) { return .board(board: board) }
        return nil
    }

    // MARK: Pieces

    private static func parseLink(_ text: String) -> NavigationTarget? {
        // Accept a bare host as well as a full URL, the way a browser would.
        let candidate = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: candidate) else { return parsePath(text) }

        if let host = url.host()?.lowercased() {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard knownHosts.contains(bare) else {
                // A path-only input has no host and is handled below; a foreign
                // host is not ours to open.
                return text.hasPrefix("/") ? parsePath(text) : nil
            }
            return parsePath(url.path(), fragment: url.fragment())
        }
        return parsePath(text)
    }

    private static func parsePath(_ path: String, fragment: String? = nil) -> NavigationTarget? {
        var path = path
        var anchor = fragment
        if anchor == nil, let hash = path.firstIndex(of: "#") {
            anchor = String(path[path.index(after: hash)...])
            path = String(path[..<hash])
        }

        let segments = path.split(separator: "/").map(String.init)
        guard let rawBoard = segments.first, let board = BoardCode.normalized(rawBoard) else {
            return nil
        }

        // /{board}/res/{num}.html
        if segments.count >= 3, segments[1] == "res" {
            let numberPart = segments[2].prefix { $0.isNumber }
            guard let threadNum = Int(numberPart) else { return nil }
            if let anchor, let postNum = Int(anchor.prefix { $0.isNumber }), postNum != threadNum {
                return .threadAtPost(board: board, threadNum: threadNum, postNum: postNum)
            }
            return .thread(board: board, threadNum: threadNum)
        }

        // /{board}/ , /{board}/index.html , /{board}/catalog.html
        if segments.count == 1 || ["index", "catalog", "catalog_num"].contains(
            segments[1].split(separator: ".").first.map(String.init) ?? ""
        ) {
            return .board(board: board)
        }
        return nil
    }

    private static func parsePostNumber(_ text: String, currentBoard: String?) -> NavigationTarget? {
        let digits = text.hasPrefix(">>") ? String(text.dropFirst(2)) : text
        guard digits.allSatisfy(\.isNumber), !digits.isEmpty, let num = Int(digits) else {
            return nil
        }
        guard let currentBoard, BoardCode.normalized(currentBoard) != nil else { return nil }
        return .post(board: currentBoard, num: num)
    }

    private static func parseBoardCode(_ text: String) -> String? {
        BoardCode.normalized(text)
    }
}
