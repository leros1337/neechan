import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import Testing
@testable import NeechanUI

/// The address a file's long-press menu copies, shares and opens.
///
/// It was the post's page. Someone who long-presses a video and copies its
/// link wants the video itself, to paste into a player or another chat; the
/// post is one "Go to post" away in the same menu.
@Suite("The link to a file")
@MainActor
struct GalleryFileLinkTests {
    private func item(site: Imageboard, path: String) throws -> GalleryItem {
        let json = """
        {"path": "\(path)", "thumbnail": "\(path)", "name": "f.webm", "type": 6}
        """
        let attachment = try JSONDecoder().decode(
            NeechanAPI.Attachment.self, from: Data(json.utf8)
        )
        return GalleryItem(
            attachment: attachment, postNum: 42,
            threadKey: ThreadKey(site: site, board: "b", threadNum: 7)
        )
    }

    @Test("a 2ch file links to the file, on the mirror being read")
    func dvachFile() throws {
        let item = try item(site: .dvach, path: "/b/src/7/1790.webm")

        #expect(item.fileURL(mirror: .life) == URL(string: "https://2ch.life/b/src/7/1790.webm"))
        #expect(item.fileURL(mirror: .org) == URL(string: "https://2ch.org/b/src/7/1790.webm"))
    }

    @Test("a 4chan file links to 4chan's media host")
    func fourchanFile() throws {
        let item = try item(site: .fourchan, path: "https://i.4cdn.org/b/1790.webm")

        #expect(item.fileURL(mirror: .default) == URL(string: "https://i.4cdn.org/b/1790.webm"))
    }

    @Test("the link is the file, not the post it was attached to")
    func notThePost() throws {
        let item = try item(site: .dvach, path: "/b/src/7/1790.webm")
        let post = SiteLinks.post(
            board: "b", threadNum: 7, postNum: 42,
            on: SiteSelection(site: .dvach, mirror: .default)
        )

        #expect(item.fileURL(mirror: .default) != post)
        #expect(item.fileURL(mirror: .default)?.lastPathComponent == "1790.webm")
    }

    /// The viewer plays from the same address the menu hands out, so a copied
    /// link is exactly the file that was on screen.
    @Test("the viewer plays the file the menu links to")
    func viewerAgrees() throws {
        let item = try item(site: .dvach, path: "/b/src/7/1790.webm")
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "file-link.\(UUID().uuidString)")!
        )
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        let model = GalleryViewModel(items: [item], startIndex: 0, services: services)

        #expect(model.url(for: item) == item.fileURL(mirror: settings.domain))
    }
}
