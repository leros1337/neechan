import Foundation
import NeechanAPI
import NeechanCore
import Testing
@testable import NeechanUI

/// Looking a file up on an image search engine.
@Suite("Reverse image search")
struct ReverseImageSearchTests {
    private func item(site: Imageboard = .dvach, path: String, thumbnail: String, type: Int) throws -> GalleryItem {
        let json = """
        {"path": "\(path)", "thumbnail": "\(thumbnail)", "name": "f", "type": \(type)}
        """
        let attachment = try JSONDecoder().decode(
            NeechanAPI.Attachment.self, from: Data(json.utf8)
        )
        return GalleryItem(
            attachment: attachment, postNum: 42,
            threadKey: ThreadKey(site: site, board: "b", threadNum: 7)
        )
    }

    /// The picture's own address goes in as one query value, so its slashes,
    /// colon and any query of its own must not leak into the engine's URL.
    @Test("each engine gets the picture's address as one encoded value", arguments: [
        (ReverseImageSearch.yandex, "https://yandex.com/images/search?rpt=imageview&url="),
        (.googleLens, "https://lens.google.com/uploadbyurl?url="),
        (.sauceNAO, "https://saucenao.com/search.php?url="),
        (.iqdb, "https://iqdb.org/?url="),
    ])
    func engineURL(engine: ReverseImageSearch, prefix: String) throws {
        let image = try #require(URL(string: "https://2ch.org/b/src/7/1790.jpg?x=1&y=2"))

        let url = engine.url(for: image).absoluteString

        #expect(url == prefix + "https%3A%2F%2F2ch.org%2Fb%2Fsrc%2F7%2F1790.jpg%3Fx%3D1%26y%3D2")
    }

    @Test("a picture is searched by the file itself")
    func pictureUsesFile() throws {
        let item = try item(path: "/b/src/7/1790.jpg", thumbnail: "/b/thumb/7/1790s.jpg", type: 1)

        #expect(item.searchableImageURL(mirror: .org) == URL(string: "https://2ch.org/b/src/7/1790.jpg"))
    }

    /// No engine takes a video, but every one takes the still the site made
    /// of it.
    @Test("a video is searched by its thumbnail")
    func videoUsesThumbnail() throws {
        let item = try item(path: "/b/src/7/1790.webm", thumbnail: "/b/thumb/7/1790s.jpg", type: 6)

        #expect(item.searchableImageURL(mirror: .life) == URL(string: "https://2ch.life/b/thumb/7/1790s.jpg"))
    }

    @Test("a 4chan file is searched on 4chan's media host")
    func fourchanFile() throws {
        let item = try item(
            site: .fourchan,
            path: "https://i.4cdn.org/b/1790.png",
            thumbnail: "https://i.4cdn.org/b/1790s.jpg",
            type: 2
        )

        #expect(item.searchableImageURL(mirror: .default) == URL(string: "https://i.4cdn.org/b/1790.png"))
    }

    /// A thread saved for offline reading keeps its files on the device. An
    /// engine on the internet cannot fetch an address on this phone.
    @Test("a file saved on the device cannot be searched")
    func savedFileIsNotSearchable() throws {
        let item = try item(path: "file:///tmp/saved/1790.jpg", thumbnail: "file:///tmp/saved/1790s.jpg", type: 1)

        #expect(item.searchableImageURL(mirror: .org) == nil)
    }
}
