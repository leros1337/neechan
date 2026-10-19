import AVFoundation
import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanMedia
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// "Save and Share" keeps a file to hand to another app rather than to Photos.
///
/// Plain Share passes on whatever the board served. This one names the file the
/// way a save would and turns a WebM into an MP4 first, because most apps the
/// share sheet offers cannot play a WebM.
@Suite("Save and share", .serialized)
@MainActor
struct SaveAndShareTests {
    /// Hands back the bytes it is given, under the extension of the URL asked
    /// for, and can be made to fail or held open.
    private final class StubDownloader: MediaDownloading, @unchecked Sendable {
        let contents: Data
        let failure: (any Error)?
        let holdsOpen: Bool

        init(contents: Data = Data([0xFF]), failure: (any Error)? = nil, holdsOpen: Bool = false) {
            self.contents = contents
            self.failure = failure
            self.holdsOpen = holdsOpen
        }

        func download(
            _ url: URL,
            referer: URL?,
            onProgress: (@Sendable (Downloader.Progress) -> Void)?
        ) async throws -> URL {
            if let failure { throw failure }
            while holdsOpen, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            try contents.write(to: file)
            return file
        }
    }

    /// Whatever a call that has not come back yet ends with.
    @MainActor
    private final class Outcome {
        var isFinished = false
        var file: URL?
    }

    private struct Setup {
        let controller: MediaTransferController
        let settings: AppSettings
        let shareDirectory: URL
    }

    private func makeSetup(_ downloader: any MediaDownloading) throws -> Setup {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "save-and-share.\(UUID().uuidString)")!
        )
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        // A cache, a block store and a share folder of this test's own.
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let shareDirectory = directory.appending(path: "share")
        let controller = MediaTransferController(
            services: services,
            downloader: downloader,
            cache: MediaCache(directory: directory.appending(path: "files")),
            blocks: MediaBlockStore(directory: directory.appending(path: "blocks")),
            shareDirectory: shareDirectory
        )
        return Setup(controller: controller, settings: settings, shareDirectory: shareDirectory)
    }

    /// Type 1 is a JPEG, type 6 a WebM.
    private func makeItem(_ number: Int, webm: Bool = false) throws -> GalleryItem {
        let ending = webm ? "webm" : "jpg"
        let json = """
        {"path": "/b/src/1/\(number).\(ending)", "thumbnail": "/b/thumb/1/\(number)s.jpg", \
        "name": "\(number).\(ending)", "type": \(webm ? 6 : 1)}
        """
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        return GalleryItem(
            attachment: attachment,
            postNum: 7,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
    }

    private func url(for item: GalleryItem) throws -> URL {
        try #require(URL(string: "https://2ch.org\(item.attachment.path)"))
    }

    /// The name a save would give the file.
    private func savedName(of item: GalleryItem) -> String {
        DownloadNaming.fileName(
            for: item.attachment,
            in: item.threadKey,
            postNum: item.postNum,
            style: .detailed
        )
    }

    private func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Waits for something to become true, so a test never sleeps longer than it
    /// has to and never hangs when it does not happen.
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

    @Test("an image comes back in the share folder, under the name a save gives it")
    func imageIsNamedAndKept() async throws {
        let setup = try makeSetup(StubDownloader())
        let item = try makeItem(3)

        let file = try #require(await setup.controller.fileForSaveAndShare(item, at: try url(for: item)))

        #expect(file.deletingLastPathComponent().standardizedFileURL
            == setup.shareDirectory.standardizedFileURL)
        #expect(file.lastPathComponent == savedName(of: item))
        #expect(FileManager.default.contents(atPath: file.path) == Data([0xFF]))
        #expect(setup.controller.transfer == nil, "the share sheet is the answer; no capsule is left up")
        #expect(setup.controller.saveResult == nil)
    }

    @Test("a WebM comes back as an MP4 that plays")
    func webmIsConverted() async throws {
        let setup = try makeSetup(StubDownloader(contents: try FixtureLoader.data(.sampleVideo)))
        let item = try makeItem(4, webm: true)

        let file = try #require(await setup.controller.fileForSaveAndShare(item, at: try url(for: item)))

        #expect(file.pathExtension == "mp4")
        #expect(file.deletingPathExtension().lastPathComponent
            == (savedName(of: item) as NSString).deletingPathExtension)
        let tracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty, "the converted file holds no video")
        #expect(contents(of: setup.shareDirectory) == [file.lastPathComponent], "the WebM is not left behind")
    }

    @Test("a WebM is converted for sharing even with conversion off for saves")
    func webmIsConvertedWhateverTheSetting() async throws {
        let setup = try makeSetup(StubDownloader(contents: try FixtureLoader.data(.sampleVideo)))
        setup.settings.convertsWebMOnSave = false
        let item = try makeItem(5, webm: true)

        let file = try #require(await setup.controller.fileForSaveAndShare(item, at: try url(for: item)))

        #expect(file.pathExtension == "mp4")
    }

    @Test("a WebM that will not convert is reported, and nothing is shared")
    func failedConversionIsReported() async throws {
        let setup = try makeSetup(StubDownloader(contents: Data("not a webm".utf8)))
        let item = try makeItem(6, webm: true)

        let file = await setup.controller.fileForSaveAndShare(item, at: try url(for: item))

        #expect(file == nil)
        #expect(setup.controller.saveResult != nil, "a share that silently does nothing reads as a dead button")
        #expect(setup.controller.transfer == nil)
        #expect(contents(of: setup.shareDirectory).isEmpty)
    }

    @Test("a failed download is reported, and nothing is shared")
    func failedDownloadIsReported() async throws {
        let setup = try makeSetup(StubDownloader(failure: Downloader.DownloadError.badStatus(503)))
        let item = try makeItem(7)

        let file = await setup.controller.fileForSaveAndShare(item, at: try url(for: item))

        #expect(file == nil)
        #expect(setup.controller.saveResult != nil)
        #expect(setup.controller.transfer == nil)
    }

    @Test("cancelling stops it, clears the capsule, and is not a failure")
    func cancelStopsIt() async throws {
        let setup = try makeSetup(StubDownloader(holdsOpen: true))
        let item = try makeItem(8)
        let target = try url(for: item)
        let controller = setup.controller

        let task = Task { await controller.fileForSaveAndShare(item, at: target) }
        #expect(await waitFor { controller.transfer?.stage == .downloading })
        controller.cancelTransfer()
        let file = await task.value

        #expect(file == nil)
        #expect(controller.transfer == nil)
        #expect(controller.saveResult == nil, "cancelling is not a failure worth an alert")
        #expect(contents(of: setup.shareDirectory).isEmpty)
    }

    @Test("the next save and share clears away the one before")
    func nextShareClearsThePrevious() async throws {
        let setup = try makeSetup(StubDownloader())
        let first = try makeItem(9)
        let second = try makeItem(10)

        let firstFile = try #require(await setup.controller.fileForSaveAndShare(first, at: try url(for: first)))
        let secondFile = try #require(await setup.controller.fileForSaveAndShare(second, at: try url(for: second)))

        #expect(!FileManager.default.fileExists(atPath: firstFile.path))
        #expect(contents(of: setup.shareDirectory) == [secondFile.lastPathComponent])
    }

    @Test("pressed while a save is running, it does nothing and leaves the save alone")
    func waitsForNoOneElse() async throws {
        let setup = try makeSetup(StubDownloader(holdsOpen: true))
        let controller = setup.controller
        let saving = try makeItem(11)
        let sharing = try makeItem(12)
        let target = try url(for: sharing)

        controller.save(saving, at: try url(for: saving))
        #expect(await waitFor { controller.transfer?.stage == .downloading })

        let outcome = Outcome()
        let task = Task {
            outcome.file = await controller.fileForSaveAndShare(sharing, at: target)
            outcome.isFinished = true
        }
        defer {
            controller.cancelTransfer()
            task.cancel()
        }

        #expect(await waitFor { outcome.isFinished }, "it waited behind the save instead of declining")
        #expect(outcome.file == nil)
        #expect(controller.transfer?.stage == .downloading, "the save it found running was disturbed")
    }
}
