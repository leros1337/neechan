import Foundation

/// Identifies one thread on one board.
///
/// Used as the key for per-thread repositories, caches and stored records.
/// Deliberately does not carry the domain: the same thread is the same thread
/// on either mirror.
public struct ThreadKey: Hashable, Sendable, Codable {
    public let board: String
    public let threadNum: Int

    public init(board: String, threadNum: Int) {
        self.board = board
        self.threadNum = threadNum
    }
}

extension ThreadKey: CustomStringConvertible {
    public var description: String { "/\(board)/\(threadNum)" }
}
