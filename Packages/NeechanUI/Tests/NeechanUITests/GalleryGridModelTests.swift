import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanMedia
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// A long press in the thread's gallery grid saves and shares the file pressed.
///
/// The grid has no file "on screen" the way the viewer does: every cell is one,
/// so each action names its item rather than reaching for a current index.
@Suite("Gallery grid actions", .serialized)
@MainActor
struct GalleryGridModelTests {
    /// Records what it was asked for, and can be made to fail.
    private final class RecordingDownloader: MediaDownloading, @unchecked Sendable {
        let failure: (any Error)?
        private let lock = NSLock()
        private var _requested: [URL] = []
        var requested: [URL] { lock.withLock { _requested } }

        init(failure: (any Error)? = nil) {
            self.failure = failure
        }

        func download(
            _ url: URL,
            referer: URL?,
            onProgress: (@Sendable (Downloader.Progress) -> Void)?
        ) async throws -> URL {
            lock.withLock { _requested.append(url) }
            if let failure { throw failure }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            FileManager.default.createFile(atPath: file.path, contents: Data([0xFF]))
            return file
        }
    }

    private func makeItem(_ number: Int, postNum: Int) throws -> GalleryItem {
        let json = """
        {"path": "/b/src/1/\(number).jpg", "thumbnail": "/b/thumb/1/\(number)s.jpg", \
        "name": "\(number).jpg", "type": 1}
        """
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        return GalleryItem(
            attachment: attachment,
            postNum: postNum,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
    }

    private func makeModel(
        _ downloader: any MediaDownloading,
        savingTo folder: URL? = nil
    ) throws -> GalleryGridModel {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "gallery-grid.\(UUID().uuidString)")!
        )
        // Photos cannot be authorised under `swift test`.
        if let folder {
            settings.savesToPhotos = false
            settings.downloadFolderBookmark = try FileDownloadSaver.bookmark(for: folder)
        }
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        return GalleryGridModel(
            services: services,
            transfers: MediaTransferController(
                services: services,
                downloader: downloader,
                cache: MediaCache(directory: directory.appending(path: "files")),
                blocks: MediaBlockStore(directory: directory.appending(path: "blocks"))
            )
        )
    }

    private func makeFolder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitFor(
        _ condition: @escaping @MainActor () -> Bool,
        within seconds: Double = 5
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("the file's address is the attachment's path on the site")
    func urlIsTheAttachmentPath() throws {
        let model = try makeModel(RecordingDownloader())
        let item = try makeItem(2, postNum: 9)

        let url = try #require(model.url(for: item))

        #expect(url.path == "/b/src/1/2.jpg")
    }

    @Test("saving fetches the file that was pressed, not the first one")
    func saveFetchesThePressedItem() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloader = RecordingDownloader()
        let model = try makeModel(downloader, savingTo: folder)
        let pressed = try makeItem(2, postNum: 9)

        model.save(pressed)

        #expect(await waitFor { model.transfers.transfer?.stage == .finished })
        #expect(downloader.requested.map(\.lastPathComponent) == ["2.jpg"])
    }

    @Test("a failed save is reported")
    func failedSaveIsReported() async throws {
        let model = try makeModel(
            RecordingDownloader(failure: Downloader.DownloadError.badStatus(503))
        )

        model.save(try makeItem(1, postNum: 7))

        #expect(await waitFor { model.transfers.saveResult != nil })
        #expect(model.transfers.transfer == nil)
    }

    @Test("sharing hands back the pressed file, downloaded")
    func shareReturnsThePressedFile() async throws {
        let downloader = RecordingDownloader()
        let model = try makeModel(downloader)

        let file = await model.fileForSharing(try makeItem(3, postNum: 11))

        #expect(file != nil)
        #expect(downloader.requested.map(\.lastPathComponent) == ["3.jpg"])
    }

    @Test("a share whose download fails hands back nothing")
    func failedShareReturnsNil() async throws {
        let model = try makeModel(
            RecordingDownloader(failure: Downloader.DownloadError.badStatus(503))
        )

        let file = await model.fileForSharing(try makeItem(1, postNum: 7))

        #expect(file == nil)
    }
}
