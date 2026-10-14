import Foundation
import Testing
@testable import NeechanUI

/// Which page the gallery fetches ahead of the reader.
///
/// Only the next picture is fetched, and only when it is no larger than 10 MB:
/// a picture larger than that costs a reader on a metered connection real
/// money for a page they may never turn to.
@Suite("Gallery preload policy")
struct GalleryPreloadPolicyTests {
    private typealias F = GalleryPreloadFixtures

    @Test("the next picture is fetched ahead")
    func nextPicture() throws {
        let items = [try F.item("a.jpg", postNum: 1), try F.item("b.jpg", postNum: 2)]

        #expect(GalleryPreloadPolicy.pictureToPreload(after: 0, in: items)?.id == items[1].id)
    }

    @Test("a picture of exactly 10 MB is fetched ahead")
    func atTheLimit() throws {
        let items = [
            try F.item("a.jpg", postNum: 1),
            try F.item("b.jpg", sizeKB: 10 * 1024, postNum: 2),
        ]

        #expect(GalleryPreloadPolicy.pictureToPreload(after: 0, in: items) != nil)
    }

    @Test("a picture over 10 MB waits for the reader")
    func overTheLimit() throws {
        let items = [
            try F.item("a.jpg", postNum: 1),
            try F.item("b.jpg", sizeKB: 10 * 1024 + 1, postNum: 2),
        ]

        #expect(GalleryPreloadPolicy.pictureToPreload(after: 0, in: items) == nil)
    }

    @Test("a picture whose size the server did not report waits for the reader")
    func unknownSize() throws {
        let items = [
            try F.item("a.jpg", postNum: 1),
            try F.item("b.jpg", sizeKB: 0, postNum: 2),
        ]

        #expect(GalleryPreloadPolicy.pictureToPreload(after: 0, in: items) == nil)
    }

    @Test("a video next is left to the video warmer")
    func nextIsAVideo() throws {
        let items = [
            try F.item("a.jpg", postNum: 1),
            try F.item("b.mp4", type: 10, postNum: 2),
            try F.item("c.jpg", postNum: 3),
        ]

        #expect(GalleryPreloadPolicy.pictureToPreload(after: 0, in: items) == nil)
    }

    @Test("an animation counts as a picture")
    func animation() throws {
        let items = [try F.item("a.jpg", postNum: 1), try F.item("b.gif", type: 4, postNum: 2)]

        #expect(GalleryPreloadPolicy.pictureToPreload(after: 0, in: items)?.id == items[1].id)
    }

    @Test("the last page has nothing after it")
    func lastPage() throws {
        let items = [try F.item("a.jpg", postNum: 1), try F.item("b.jpg", postNum: 2)]

        #expect(GalleryPreloadPolicy.pictureToPreload(after: 1, in: items) == nil)
        #expect(GalleryPreloadPolicy.pictureToPreload(after: 5, in: items) == nil)
        #expect(GalleryPreloadPolicy.pictureToPreload(after: -1, in: []) == nil)
    }
}
