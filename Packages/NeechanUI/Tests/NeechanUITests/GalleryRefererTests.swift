import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import Testing
@testable import NeechanUI

/// Which page a media request claims to have come from.
///
/// The regression: every media request in the gallery named the 2ch mirror as
/// its referer whichever site the file was on. 4chan's media host serves a
/// thumbnail to anyone but refuses a full-size file linked from another site,
/// so on 4chan every thumbnail loaded and every full image was a 403. Checked
/// against the host directly on 2026-09-20: the same file answers 206 with
/// no referer or a 4chan one, and 403 with a 2ch one.
@Suite("The referer a gallery sends")
@MainActor
struct GalleryRefererTests {
    private func item(site: Imageboard, path: String) throws -> GalleryItem {
        let json = """
        {"path": "\(path)", "thumbnail": "\(path)", "name": "f.jpg", "type": 1}
        """
        let attachment = try JSONDecoder().decode(
            NeechanAPI.Attachment.self, from: Data(json.utf8)
        )
        return GalleryItem(
            attachment: attachment, postNum: 1,
            threadKey: ThreadKey(site: site, board: "g", threadNum: 1)
        )
    }

    private func makeModel(_ item: GalleryItem) throws -> GalleryViewModel {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "referer.\(UUID().uuidString)")!
        )
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        return GalleryViewModel(items: [item], startIndex: 0, services: services)
    }

    @Test("a 4chan file is linked from 4chan's own site")
    func fourchanReferer() throws {
        let item = try item(site: .fourchan, path: "https://i.4cdn.org/g/1.jpg")

        let endpoints = item.endpoints(mirror: .default)

        #expect(endpoints.web == URL(string: "https://boards.4chan.org"))
        #expect(endpoints.url(forPath: item.attachment.path) == URL(string: "https://i.4cdn.org/g/1.jpg"))
    }

    @Test("a 2ch file is linked from the mirror it was read on, as before")
    func dvachReferer() throws {
        let item = try item(site: .dvach, path: "/b/src/1/1.jpg")

        let endpoints = item.endpoints(mirror: .default)

        #expect(endpoints.web == DvachDomain.default.baseURL)
        #expect(endpoints.url(forPath: item.attachment.path)?.host() == DvachDomain.default.baseURL.host())
    }

    @Test("the player is told the same, whatever mirror the settings hold")
    func playerOptionsCarryTheSiteReferer() throws {
        let item = try item(site: .fourchan, path: "https://i.4cdn.org/g/1.mp4")
        let model = try makeModel(item)

        let options = model.playerOptions(for: item)

        #expect(options.httpHeaders["Referer"] == "https://boards.4chan.org")
        #expect(model.referer(for: item) == URL(string: "https://boards.4chan.org"))
    }
}
