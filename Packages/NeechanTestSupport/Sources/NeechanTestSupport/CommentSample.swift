import Foundation

/// One recorded post comment (raw HTML as the server returns it), used as the
/// corpus for the comment parser tests.
public struct CommentSample: Decodable, Sendable {
    public let num: Int
    public let comment: String
}

extension FixtureLoader {
    /// The recorded comment corpus, ordered as captured.
    public static func commentSamples() throws -> [CommentSample] {
        try decode([CommentSample].self, from: .commentSamples)
    }
}
