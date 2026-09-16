import Foundation
import NeechanCore
import NeechanMedia
import Synchronization
import Testing
@testable import NeechanUI

/// Video comes onto the device through the app's own downloader before it is
/// played, because the engine's own HTTP client is refused by Cloudflare on one
/// of the mirrors.
@Suite("Local media files", .serialized)
struct LocalMediaFileTests {
    /// A downloader that writes a marker file and counts its calls.
    private final class StubDownloader: MediaDownloading, @unchecked Sendable {
        var calls = 0
        var failure: (any Error)?

        func download(
            _ url: URL,
            referer: URL?,
            onProgress: (@Sendable (Downloader.Progress) -> Void)?
        ) async throws -> URL {
            calls += 1
            if let failure { throw failure }
            onProgress?(Downloader.Progress(bytesReceived: 5, bytesExpected: 10))
            onProgress?(Downloader.Progress(bytesReceived: 10, bytesExpected: 10))
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            try Data("video".utf8).write(to: file)
            return file
        }
    }

    private func uniqueURL() -> URL {
        URL(string: "https://2ch.life/b/src/1/\(UUID().uuidString).webm")!
    }

    @Test("a file is downloaded once and then comes from the cache")
    func downloadsOnceThenCaches() async throws {
        let downloader = StubDownloader()
        let url = uniqueURL()

        let first = try await LocalMediaFile.resolve(url, referer: nil, downloader: downloader)
        let second = try await LocalMediaFile.resolve(url, referer: nil, downloader: downloader)

        #expect(first.isFileURL)
        #expect(second == first, "the second ask should be the cached copy")
        #expect(downloader.calls == 1, "the file was fetched again although it was cached")
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("progress is passed through while a download runs")
    func reportsProgress() async throws {
        let downloader = StubDownloader()
        let seen = Mutex<[Double]>([])

        _ = try await LocalMediaFile.resolve(uniqueURL(), referer: nil, downloader: downloader) { progress in
            if let fraction = progress.fraction { seen.withLock { $0.append(fraction) } }
        }

        #expect(seen.withLock { $0 } == [0.5, 1.0])
    }

    @Test("a download that fails is a failure, not a silent nothing")
    func failurePropagates() async {
        let downloader = StubDownloader()
        downloader.failure = Downloader.DownloadError.badStatus(403)

        await #expect(throws: Downloader.DownloadError.self) {
            _ = try await LocalMediaFile.resolve(uniqueURL(), referer: nil, downloader: downloader)
        }
    }
}
