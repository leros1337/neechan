import Foundation
import NeechanAPI

/// Identifies one thread on one board of one imageboard.
///
/// Used as the key for per-thread repositories, caches and stored records.
/// Deliberately does not carry the *domain*: the same thread is the same thread
/// on either 2ch mirror. It does carry the site, because `/b/12345` on 2ch and
/// `/b/12345` on 4chan are two different threads that happen to be written the
/// same way — and because this is the key `AppServices` caches thread
/// repositories under, so without it one site would hand back the other's.
public struct ThreadKey: Hashable, Sendable, Codable {
    public let site: Imageboard
    public let board: String
    public let threadNum: Int

    public init(site: Imageboard, board: String, threadNum: Int) {
        self.site = site
        self.board = board
        self.threadNum = threadNum
    }
}

extension ThreadKey {
    /// `/b/12345`, the way a reader writes it.
    ///
    /// Without the site on purpose: this is shown to people, and
    /// `/dvach/b/12345` reads like a board called `dvach`. Anything that needs
    /// to tell two sites apart wants `identifier`.
    public var description: String { "/\(board)/\(threadNum)" }

    /// A name safe for a filesystem path, a notification identifier or a
    /// download folder, and unique across sites.
    public var identifier: String { "\(site.rawValue)-\(board)-\(threadNum)" }

    /// The board this thread is on.
    public var boardRef: BoardRef { BoardRef(site: site, code: board) }
}

extension ThreadKey: CustomStringConvertible {}

extension ThreadKey {
    private enum CodingKeys: String, CodingKey { case site, board, threadNum }

    /// Written by hand rather than left to synthesis.
    ///
    /// `Codable`'s generated decoder throws `keyNotFound` for a missing key
    /// whatever default the property has, so a value encoded before there were
    /// two sites would fail to read. It was 2ch's.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = try container.decodeIfPresent(Imageboard.self, forKey: .site) ?? .dvach
        board = try container.decode(String.self, forKey: .board)
        threadNum = try container.decode(Int.self, forKey: .threadNum)
    }
}

/// One board on one imageboard.
///
/// The board-scoped counterpart of `ThreadKey`, for the queries and settings
/// that name a board rather than a thread. `/b/` exists on both sites.
public struct BoardRef: Hashable, Sendable, Codable {
    public let site: Imageboard
    public let code: String

    public init(site: Imageboard, code: String) {
        self.site = site
        self.code = code
    }

    /// `/b/`, the way the site writes it. Without the imageboard, for the same
    /// reason `ThreadKey.description` is.
    public var displayCode: String { "/\(code)/" }
}
