import Foundation
import NeechanAPI
import NeechanCore
import Testing
@testable import NeechanUI

/// What makes one thing in a gallery different from another.
///
/// The regression this exists for: identity was the file's path alone, and
/// threads repost. The same file under two posts gave two items claiming to be
/// the same one, and a list keyed on that renders both where it means to
/// render one. In the gallery that meant two players opening the same clip and
/// playing it twice over itself; in the feed, it could not tell which of the
/// two it had scrolled to.
@Suite("Telling one attachment from another")
struct GalleryItemIdentityTests {
    /// Built the way the app builds one, from what a board actually answers
    /// with, so the identity under test is the real one.
    private func item(named name: String, postNum: Int) throws -> GalleryItem {
        let json = """
        {"path": "/b/src/1/\(name)", "thumbnail": "/b/thumb/1/s.jpg", \
        "name": "\(name)", "type": 10}
        """
        let attachment = try JSONDecoder().decode(
            NeechanAPI.Attachment.self, from: Data(json.utf8)
        )
        return GalleryItem(
            attachment: attachment,
            postNum: postNum,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
    }

    /// The case that broke it: one file, two posts.
    @Test("the same file reposted is two different things")
    func repostsAreDistinct() throws {
        let first = try item(named: "123.mp4", postNum: 100)
        let second = try item(named: "123.mp4", postNum: 200)

        #expect(first.id != second.id, "a repost shares its identity with the original")
    }

    @Test("the same file in the same post is the same thing")
    func oneAttachmentIsItself() throws {
        let once = try item(named: "123.mp4", postNum: 100)
        let again = try item(named: "123.mp4", postNum: 100)
        #expect(once.id == again.id)
    }

    @Test("two files in one post are two different things")
    func siblingsAreDistinct() throws {
        let video = try item(named: "123.mp4", postNum: 100)
        let other = try item(named: "124.mp4", postNum: 100)
        #expect(video.id != other.id)
    }

    /// A gallery keys its pages on this, so a thread full of reposts must
    /// still give one page per attachment.
    @Test("a thread of reposts gives one identity per attachment")
    func aThreadOfRepostsHasNoCollisions() throws {
        let items = [
            try item(named: "a.mp4", postNum: 1),
            try item(named: "a.mp4", postNum: 2),
            try item(named: "a.mp4", postNum: 3),
            try item(named: "b.mp4", postNum: 2)
        ]
        #expect(Set(items.map(\.id)).count == items.count, "two of them share an identity")
    }
}
