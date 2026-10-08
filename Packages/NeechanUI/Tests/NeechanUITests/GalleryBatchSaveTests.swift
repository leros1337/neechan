import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanMedia
import NeechanSettings
import Synchronization
import Testing
@testable import NeechanUI

/// Saving many files at once: a selection from the grid, or a whole thread.
@Suite("Saving many files", .serialized)
@MainActor
struct GalleryBatchSaveTests {
    /// Writes a one-byte file per request, remembering the order they came in.
    /// Can refuse one address, and can hold the first request open.
    private final class RecordingDownloader: MediaDownloading, Sendable {
        let failing: Set<URL>
        let holdsFirst: Bool
        let delay: Duration
        private let requested = Mutex<[URL]>([])

        init(failing: Set<URL> = [], holdsFirst: Bool = false, delay: Duration = .zero) {
            self.failing = failing
            self.holdsFirst = holdsFirst
            self.delay = delay
        }

        var urls: [URL] { requested.withLock { $0 } }

        func download(
            _ url: URL,
            referer: URL?,
            onProgress: (@Sendable (Downloader.Progress) -> Void)?
        ) async throws -> URL {
            let isFirst = requested.withLock { list in
                list.append(url)
                return list.count == 1
            }
            if delay > .zero { try? await Task.sleep(for: delay) }
            while holdsFirst, isFirst, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if Task.isCancelled { throw Downloader.DownloadError.cancelled }
            if failing.contains(url) { throw Downloader.DownloadError.badStatus(404) }
            let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".jpg")
            FileManager.default.createFile(atPath: file.path, contents: Data([0xFF]))
            return file
        }
    }

    private struct Fixture {
        let services: AppServices
        let controller: MediaTransferController
        let folder: URL
        let items: [GalleryItem]

        func job(_ index: Int) -> (GalleryItem, URL) {
            (items[index], url(index))
        }

        func url(_ index: Int) -> URL { Fixture.url(index) }

        static func url(_ index: Int) -> URL {
            URL(string: "https://2ch.org/b/src/1/\(index + 1).jpg")!
        }

        /// Every file saved into the folder, wherever the template put it.
        var savedFiles: [String] {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { !$0.hasDirectoryPath } ?? []
            return files.map(\.lastPathComponent).sorted()
        }
    }

    private func makeFixture(_ downloader: RecordingDownloader, count: Int = 3) throws -> Fixture {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "batch.\(UUID().uuidString)")!)
        // Photos cannot be authorised under `swift test`.
        settings.savesToPhotos = false
        settings.downloadFolderBookmark = try FileDownloadSaver.bookmark(for: folder)
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let controller = MediaTransferController(
            services: services,
            downloader: downloader,
            cache: MediaCache(directory: directory.appending(path: "files")),
            blocks: MediaBlockStore(directory: directory.appending(path: "blocks"))
        )
        let items = try (1...count).map { number in
            let json = #"{"path": "/b/src/1/\#(number).jpg", "thumbnail": "/b/thumb/1/\#(number)s.jpg", "name": "\#(number).jpg", "type": 1}"#
            return GalleryItem(
                attachment: try JSONDecoder().decode(Attachment.self, from: Data(json.utf8)),
                postNum: 100 + number,
                threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
            )
        }
        return Fixture(services: services, controller: controller, folder: folder, items: items)
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

    @Test("every file in a batch is saved, in order")
    func batchSavesEverything() async throws {
        let downloader = RecordingDownloader()
        let fixture = try makeFixture(downloader)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        fixture.controller.save([fixture.job(0), fixture.job(1), fixture.job(2)])

        #expect(await waitFor { fixture.controller.transfer?.isFinished == true })
        #expect(downloader.urls == [fixture.url(0), fixture.url(1), fixture.url(2)])
        #expect(fixture.savedFiles.count == 3)
        #expect(fixture.controller.saveResult == nil)
    }

    @Test("the capsule says which file of how many is on its way")
    func batchReportsPosition() async throws {
        let downloader = RecordingDownloader(holdsFirst: true)
        let fixture = try makeFixture(downloader)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        fixture.controller.save([fixture.job(0), fixture.job(1), fixture.job(2)])

        #expect(await waitFor { fixture.controller.batch == .init(total: 3, done: 0, failed: 0) })
        fixture.controller.cancelTransfer()
    }

    /// The second press used to be dropped without a word while the first file
    /// was still coming down.
    @Test("a save pressed while another runs waits its turn")
    func secondSaveIsQueued() async throws {
        let downloader = RecordingDownloader(delay: .milliseconds(150))
        let fixture = try makeFixture(downloader)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        fixture.controller.save(fixture.items[0], at: fixture.url(0))
        fixture.controller.save(fixture.items[1], at: fixture.url(1))

        #expect(await waitFor { fixture.savedFiles.count == 2 })
        #expect(downloader.urls == [fixture.url(0), fixture.url(1)])
    }

    @Test("a file that fails is counted, and the rest still save")
    func failureDoesNotStopTheBatch() async throws {
        let downloader = RecordingDownloader(failing: [Fixture.url(1)])
        let fixture = try makeFixture(downloader)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        fixture.controller.save([fixture.job(0), fixture.job(1), fixture.job(2)])

        #expect(await waitFor { fixture.controller.saveResult != nil })
        #expect(downloader.urls.count == 3)
        #expect(fixture.savedFiles.count == 2)
        let message = try #require(fixture.controller.saveResult?.message)
        #expect(message.contains("1") && message.contains("3"), "says how many of how many: \(message)")
        #expect(fixture.controller.transfer == nil)
        #expect(fixture.controller.batch == nil)
    }

    @Test("cancelling stops the files still waiting")
    func cancelStopsTheRest() async throws {
        let downloader = RecordingDownloader(holdsFirst: true)
        let fixture = try makeFixture(downloader)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        fixture.controller.save([fixture.job(0), fixture.job(1), fixture.job(2)])
        #expect(await waitFor { downloader.urls.count == 1 })

        fixture.controller.cancelTransfer()
        try await Task.sleep(for: .milliseconds(200))

        #expect(downloader.urls.count == 1)
        #expect(fixture.savedFiles.isEmpty)
        #expect(fixture.controller.transfer == nil)
        #expect(fixture.controller.batch == nil)
        #expect(fixture.controller.saveResult == nil, "cancelling is not a failure worth an alert")
    }

    // MARK: Picking files in the grid

    @Test("a tap ticks a file and a second tap unticks it")
    func toggling() async throws {
        let fixture = try makeFixture(RecordingDownloader())
        let model = GalleryGridModel(services: fixture.services, transfers: fixture.controller)

        model.toggleSelection(fixture.items[1])
        #expect(model.isSelected(fixture.items[1]))
        #expect(model.isSelected(fixture.items[0]) == false)

        model.toggleSelection(fixture.items[1])
        #expect(model.selectionCount(in: fixture.items) == 0)
    }

    /// "All" means what the grid shows: with the filter on videos, the
    /// pictures the reader cannot see are not swept up with them.
    @Test("select all takes what is shown, and a second press clears it")
    func selectAllTakesWhatIsShown() async throws {
        let fixture = try makeFixture(RecordingDownloader())
        let model = GalleryGridModel(services: fixture.services, transfers: fixture.controller)
        let shown = Array(fixture.items.prefix(2))

        model.toggleSelectAll(in: shown)
        #expect(model.selectionCount(in: fixture.items) == 2)
        #expect(model.isSelected(fixture.items[2]) == false)

        model.toggleSelectAll(in: shown)
        #expect(model.selectionCount(in: fixture.items) == 0)
    }

    @Test("saving the ticked files saves them in grid order and ends the picking")
    func savingTheSelection() async throws {
        let downloader = RecordingDownloader()
        let fixture = try makeFixture(downloader)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let model = GalleryGridModel(services: fixture.services, transfers: fixture.controller)
        model.isSelecting = true
        model.toggleSelection(fixture.items[2])
        model.toggleSelection(fixture.items[0])

        model.saveSelection(in: fixture.items)

        #expect(model.isSelecting == false)
        #expect(model.selectionCount(in: fixture.items) == 0)
        #expect(await waitFor { fixture.savedFiles.count == 2 })
        #expect(downloader.urls == [fixture.url(0), fixture.url(2)])
    }
}
