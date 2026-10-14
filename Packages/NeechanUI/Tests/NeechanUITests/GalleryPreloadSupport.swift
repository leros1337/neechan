import CoreGraphics
import Foundation
import ImageIO
import NeechanAPI
import NeechanCore
import NeechanMedia
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import NeechanUI

/// What the gallery's preloading tests build their threads from.
enum GalleryPreloadFixtures {
    /// Built by decoding, the way the site delivers them. Type 1 is a JPEG,
    /// 4 a GIF and 10 an MP4; `size` is in kilobytes, as 2ch sends it.
    static func item(
        _ name: String, type: Int = 1, sizeKB: Int = 300, postNum: Int = 1
    ) throws -> GalleryItem {
        let json = """
        {"path": "/b/src/1/\(name)", "thumbnail": "/b/thumb/1/s.jpg", \
        "name": "\(name)", "type": \(type), "size": \(sizeKB)}
        """
        return GalleryItem(
            attachment: try JSONDecoder().decode(NeechanAPI.Attachment.self, from: Data(json.utf8)),
            postNum: postNum,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
    }

    /// A small PNG, built in memory so no fixture is needed.
    static func png(side: Int = 8) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A media cache of its own, so one test's files are not another's hits.
    static func cache() -> MediaCache {
        MediaCache(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "gallery-preload-\(UUID().uuidString)")
        )
    }

    /// Waits for work started in a `Task` of its own.
    @MainActor
    static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        within seconds: Double = 2
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// Stands in for the network: counts what is asked for, and answers with a
/// picture, or with a failure for the files named in `failing`.
final class CountingFetcher: MediaFetching, @unchecked Sendable {
    let asked = Mutex([URL]())
    let failing = Mutex(Set<String>())
    /// Held until released, so a test can catch a fetch in flight.
    let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let isGated: Bool
    private let body: Data

    struct Refused: Error {}

    init(body: Data, gated: Bool = false) {
        self.body = body
        self.isGated = gated
    }

    var names: [String] { asked.withLock { $0.map(\.lastPathComponent) } }

    func data(_ url: URL, referer: URL?) async throws -> Data {
        asked.withLock { $0.append(url) }
        if isGated {
            await withCheckedContinuation { continuation in
                gate.withLock { $0 = continuation }
            }
        }
        try Task.checkCancellation()
        if failing.withLock({ $0.contains(url.lastPathComponent) }) { throw Refused() }
        return body
    }

    /// Lets the fetch held at the gate go on.
    func release() {
        let continuation = gate.withLock { current -> CheckedContinuation<Void, Never>? in
            defer { current = nil }
            return current
        }
        continuation?.resume()
    }
}

/// Fetches nothing: stands in for the thing that fetches the rest of a clip,
/// so a test that plays a video does not reach for the network.
final class IdleCompleter: MediaCompleting, @unchecked Sendable {
    func complete(_ url: URL, referer: URL?, onProgress: (@Sendable (Double) -> Void)?) async {}
    func cancel(_ url: URL) async {}
    func cancelAll() async {}
}
