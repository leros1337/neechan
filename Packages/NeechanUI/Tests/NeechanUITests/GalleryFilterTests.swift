import Foundation
import NeechanAPI
import NeechanCore
import Testing
@testable import NeechanUI

/// The gallery grid narrowed to a thread's videos or its pictures.
///
/// The viewer opened from the grid is handed the narrowed list, so what is
/// asserted here is also what a swipe through it will show.
@Suite("Gallery filter")
struct GalleryFilterTests {
    /// Built by decoding, the way the site delivers them. Type 1 is a JPEG,
    /// 2 a PNG, 4 a GIF, 6 a WebM and 10 an MP4.
    private func item(_ name: String, type: Int, postNum: Int) throws -> GalleryItem {
        let json = """
        {"path": "/b/src/1/\(name)", "thumbnail": "/b/thumb/1/s.jpg", \
        "name": "\(name)", "type": \(type)}
        """
        return GalleryItem(
            attachment: try JSONDecoder().decode(NeechanAPI.Attachment.self, from: Data(json.utf8)),
            postNum: postNum,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
    }

    /// A thread's files in reading order, pictures and clips interleaved.
    private func thread() throws -> [GalleryItem] {
        [
            try item("a.jpg", type: 1, postNum: 1),
            try item("1.webm", type: 6, postNum: 2),
            try item("b.png", type: 2, postNum: 3),
            try item("c.gif", type: 4, postNum: 4),
            try item("2.mp4", type: 10, postNum: 5),
            try item("d.webp", type: 2, postNum: 6),
        ]
    }

    @Test("all keeps every file, in reading order")
    func allKeepsEverything() throws {
        let items = try thread()
        #expect(GalleryFilter.all.apply(to: items) == items)
    }

    @Test("videos keeps the clips, in the order they were posted")
    func videosKeepsClips() throws {
        let shown = GalleryFilter.videos.apply(to: try thread())
        #expect(shown.map(\.attachment.name) == ["1.webm", "2.mp4"])
    }

    @Test("images keeps the pictures, a GIF among them, and drops the clips")
    func imagesKeepsPictures() throws {
        let shown = GalleryFilter.images.apply(to: try thread())
        #expect(shown.map(\.attachment.name) == ["a.jpg", "b.png", "c.gif", "d.webp"])
    }

    /// The server's type code says JPEG, but the viewer goes by the name and
    /// plays it. The filter has to agree with the viewer, or a clip would sit
    /// among the pictures and open in a player.
    @Test("a .mov is a video whatever type the server gives it")
    func movIsAVideo() throws {
        let mov = try item("clip.mov", type: 1, postNum: 7)
        #expect(GalleryFilter.videos.includes(mov))
        #expect(!GalleryFilter.images.includes(mov))
    }

    @Test("videos and images between them hold every file once")
    func videosAndImagesPartitionTheThread() throws {
        let items = try thread()
        let videos = GalleryFilter.videos.apply(to: items)
        let images = GalleryFilter.images.apply(to: items)
        #expect(videos.count + images.count == items.count)
        #expect(Set(videos.map(\.id)).isDisjoint(with: images.map(\.id)))
        #expect(Set(videos.map(\.id)).union(images.map(\.id)) == Set(items.map(\.id)))
    }
}
