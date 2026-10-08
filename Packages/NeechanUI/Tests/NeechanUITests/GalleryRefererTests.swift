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

/// Which files are sent the reader's session.
///
/// The player writes the cookies into a header of its own on every request,
/// so whatever it is handed goes to whichever host the file is on. That was
/// only ever the selected mirror until a link in a post could open a file on
/// any host at all, and a clip on a file host has no business with the
/// reader's 2ch session.
@Suite("The cookies a gallery sends")
@MainActor
struct GalleryCookieTests {
    private func item(site: Imageboard = .dvach, path: String) -> GalleryItem {
        GalleryItem(
            attachment: NeechanAPI.Attachment(name: "f.mp4", path: path, declaredType: .mp4),
            postNum: 1,
            threadKey: ThreadKey(site: site, board: "b", threadNum: 1)
        )
    }

    private func makeModel(_ items: [GalleryItem]) throws -> GalleryViewModel {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "cookies.\(UUID().uuidString)")!
        )
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        return GalleryViewModel(
            items: items, startIndex: 0, services: services,
            cookieProvider: { _ in ["usercode_auth": "secret"] }
        )
    }

    @Test("a file on the selected mirror is sent the session, as before")
    func mirrorFile() throws {
        let file = item(path: "/b/src/1/2.mp4")
        let model = try makeModel([file])

        #expect(model.playerOptions(for: file).httpHeaders["Cookie"] == "usercode_auth=secret")
    }

    @Test(
        "a file on any other host is sent none of it",
        arguments: [
            (Imageboard.dvach, "https://files.catbox.moe/abc.mp4"),
            (Imageboard.dvach, "https://2ch.su/b/src/1/2.mp4"),
            (Imageboard.fourchan, "https://i.4cdn.org/g/1.mp4"),
        ]
    )
    func otherHosts(site: Imageboard, path: String) throws {
        let file = item(site: site, path: path)
        let model = try makeModel([file])

        #expect(model.playerOptions(for: file).httpHeaders["Cookie"] == nil)
    }

    /// The options are kept per kind of file, and two clips of one kind can
    /// now be on two hosts.
    @Test("a clip elsewhere does not inherit the session from a clip on the mirror")
    func cacheKeepsHostsApart() throws {
        let mirror = item(path: "/b/src/1/2.mp4")
        let elsewhere = item(path: "https://files.catbox.moe/abc.mp4")
        let model = try makeModel([mirror, elsewhere])

        _ = model.playerOptions(for: mirror)

        #expect(model.playerOptions(for: elsewhere).httpHeaders["Cookie"] == nil)
        #expect(model.playerOptions(for: mirror).httpHeaders["Cookie"] == "usercode_auth=secret")
    }
}
