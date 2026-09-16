import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// Saving a file says how far it has got.
///
/// The downloader has always reported progress; the gallery simply never passed
/// the callback, so a 20 MB clip looked like a button that did nothing until it
/// was suddenly finished.
@Suite("Gallery transfers", .serialized)
@MainActor
struct GalleryTransferTests {
    /// A downloader the test drives: it reports the fractions it is given, and
    /// can be held open so the capsule can be looked at mid-flight.
    private final class StubDownloader: MediaDownloading, @unchecked Sendable {
        let fractions: [Double]
        let failure: (any Error)?
        /// Held while the "download" is in flight, so a test can cancel it.
        let holdsOpen: Bool

        init(fractions: [Double] = [1], failure: (any Error)? = nil, holdsOpen: Bool = false) {
            self.fractions = fractions
            self.failure = failure
            self.holdsOpen = holdsOpen
        }

        func download(
            _ url: URL,
            referer: URL?,
            onProgress: (@Sendable (Downloader.Progress) -> Void)?
        ) async throws -> URL {
            if let failure { throw failure }
            for fraction in fractions {
                // Past the view model's throttle, which is what keeps a report
                // every 64 KB from redrawing the screen hundreds of times.
                try? await Task.sleep(for: .milliseconds(120))
                onProgress?(Downloader.Progress(
                    bytesReceived: Int64(fraction * 1000), bytesExpected: 1000
                ))
            }
            while holdsOpen, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jpg")
            FileManager.default.createFile(atPath: file.path, contents: Data([0xFF]))
            return file
        }
    }

    private func makeModel(_ downloader: any MediaDownloading) throws -> GalleryViewModel {
        let services = try AppServices.inMemory(
            settings: AppSettings(
                defaults: UserDefaults(suiteName: "gallery.\(UUID().uuidString)")!
            ),
            transport: StubTransport()
        )
        // `Attachment` is decoded from the site, so a test builds one the same
        // way rather than through an initialiser that exists only for tests.
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(#"""
        {"path": "/b/src/1/1.jpg", "thumbnail": "/b/thumb/1/1s.jpg", "name": "1.jpg", "type": 1}
        """#.utf8))
        let item = GalleryItem(
            attachment: attachment,
            postNum: 7,
            threadKey: ThreadKey(board: "b", threadNum: 1)
        )
        return GalleryViewModel(
            items: [item], startIndex: 0, services: services, downloader: downloader
        )
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

    @Test("how far a download has got reaches the capsule")
    func progressReachesTheCapsule() async throws {
        let model = try makeModel(StubDownloader(fractions: [0.5], holdsOpen: true))

        let task = Task { await model.fileForSharing() }
        defer { task.cancel() }

        #expect(await waitFor { model.transfer?.fraction == 0.5 })
    }

    @Test("a save shows the capsule before anything has arrived")
    func capsuleAppearsAtOnce() async throws {
        let model = try makeModel(StubDownloader(fractions: [0.5], holdsOpen: true))

        model.saveCurrentItem()

        #expect(await waitFor { model.transfer?.stage == .downloading })
        model.cancelTransfer()
    }

    @Test("cancelling clears the capsule and saves nothing")
    func cancelStopsTheTransfer() async throws {
        let model = try makeModel(StubDownloader(fractions: [0.5], holdsOpen: true))
        model.saveCurrentItem()
        #expect(await waitFor { model.transfer != nil })

        model.cancelTransfer()

        #expect(model.transfer == nil)
        #expect(model.saveResult == nil, "cancelling is not a failure worth an alert")
    }

    @Test("a failed download is reported and takes the capsule away")
    func failureIsReported() async throws {
        let model = try makeModel(
            StubDownloader(failure: Downloader.DownloadError.badStatus(503))
        )

        model.saveCurrentItem()

        #expect(await waitFor { model.saveResult != nil })
        #expect(model.transfer == nil, "a failure that leaves a spinner up reads as a hang")
    }

    @Test("a cancelled download is not reported as a failure")
    func cancellationIsNotAFailure() async throws {
        let model = try makeModel(
            StubDownloader(failure: Downloader.DownloadError.cancelled)
        )

        model.saveCurrentItem()

        #expect(await waitFor { model.transfer == nil })
        #expect(model.saveResult == nil)
    }
}
