import Foundation

/// One row in a catalog: the original post plus the thread's totals.
public struct ThreadSummary: Sendable, Hashable, Identifiable, Decodable {
    /// The post that opened the thread.
    public let opPost: Post
    public let postsCount: Int
    public let filesCount: Int

    public var id: Int { opPost.num }
    public var num: Int { opPost.num }
    public var board: String { opPost.board }

    /// Replies excluding the original post, never negative.
    public var replyCount: Int { max(0, postsCount - 1) }

    private enum CodingKeys: String, CodingKey {
        case postsCount = "posts_count"
        case filesCount = "files_count"
    }

    public init(from decoder: any Decoder) throws {
        // The catalog's thread object *is* a post, with two extra counters.
        opPost = try Post(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postsCount = try c.decodeIfPresent(Int.self, forKey: .postsCount) ?? 1
        filesCount = try c.decodeIfPresent(Int.self, forKey: .filesCount) ?? opPost.files.count
    }

    public init(opPost: Post, postsCount: Int, filesCount: Int) {
        self.opPost = opPost
        self.postsCount = postsCount
        self.filesCount = filesCount
    }
}
