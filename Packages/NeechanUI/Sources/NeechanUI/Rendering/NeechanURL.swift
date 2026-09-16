import Foundation
import NeechanAPI

/// The private URL scheme used inside rendered post bodies.
///
/// SwiftUI's `Text` can carry a link attribute but not an arbitrary payload, so
/// taps on `>>N` and on spoilers are expressed as links in this scheme and
/// intercepted by the thread view's `openURL` handler.
public enum NeechanURL {
    public static let scheme = "neechan"

    /// What a tap inside a post body means.
    public enum Action: Sendable, Hashable {
        /// A `>>N` reference.
        case post(board: String, threadNum: Int?, postNum: Int)
        /// Reveal or hide the spoilers in one post.
        case toggleSpoilers(postNum: Int)
        /// An ordinary web link.
        case external(URL)
    }

    /// Builds the link for a `>>N` reference.
    public static func post(_ reference: PostReference) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "post"
        components.queryItems = [
            URLQueryItem(name: "num", value: String(reference.postNum)),
            reference.board.map { URLQueryItem(name: "board", value: $0) },
            reference.threadNum.map { URLQueryItem(name: "thread", value: String($0)) },
        ].compactMap { $0 }
        return components.url
    }

    /// Builds the link that reveals the spoilers in a post.
    public static func spoilerToggle(postNum: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "spoiler"
        components.queryItems = [URLQueryItem(name: "num", value: String(postNum))]
        return components.url
    }

    /// Reads a tapped link back into an action. Anything not in this scheme is
    /// reported as an external link for the browser to handle.
    public static func action(for url: URL) -> Action {
        guard url.scheme == scheme else { return .external(url) }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch url.host() {
        case "post":
            guard let num = value("num").flatMap(Int.init) else { return .external(url) }
            return .post(
                board: value("board") ?? "",
                threadNum: value("thread").flatMap(Int.init),
                postNum: num
            )
        case "spoiler":
            guard let num = value("num").flatMap(Int.init) else { return .external(url) }
            return .toggleSpoilers(postNum: num)
        default:
            return .external(url)
        }
    }
}
