import Foundation
import ImageIO
import NeechanAPI
import os
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// Fetches, decodes and caches images.
///
/// Thumbnails are requested in bursts as a list scrolls, so identical requests
/// are coalesced: the second caller for a URL awaits the first one's task
/// instead of opening a second connection.
public actor ImageLoader {
    public static let shared = ImageLoader()

    public enum LoaderError: Error {
        case notAnImage(URL)
        /// The server answered, and said no.
        case refused(URL, status: Int)
    }

    private static let log = Logger(subsystem: "io.neechan.media", category: "images")

    /// One in-flight fetch and how many callers are waiting on it.
    private struct Load {
        let task: Task<PlatformImage, any Error>
        var waiters: Int
    }

    private struct CacheKey: Hashable {
        let url: URL
        /// Zero means "whatever size the file is".
        let maxPixelSize: Int

        /// `NSCache` keys must be objects, and the size is part of what
        /// identifies an entry: the same file decoded for a grid tile and for a
        /// full-screen page are two different images.
        var cacheIdentifier: NSString {
            "\(maxPixelSize)|\(url.absoluteString)" as NSString
        }
    }

    private let session: URLSession
    private let cache = NSCache<NSString, PlatformImage>()
    private var inFlight: [CacheKey: Load] = [:]

    public init(session: URLSession? = nil, memoryLimitBytes: Int = 64 * 1024 * 1024) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(
                memoryCapacity: 16 * 1024 * 1024,
                diskCapacity: 256 * 1024 * 1024,
                diskPath: "NeechanImages"
            )
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
        cache.totalCostLimit = memoryLimitBytes
    }

    /// The image at `url`, from memory when it is already there.
    ///
    /// - Parameter maxPixelSize: the longest side the caller will draw, in
    ///   pixels, or nil for the file's own size. Decoding to the size actually
    ///   needed is what keeps a grid of thumbnails off the main thread: without
    ///   it `UIImage(data:)` hands back an undecoded image and the pixels are
    ///   produced during the scroll, on the render thread.
    public func image(
        at url: URL,
        referer: URL? = nil,
        maxPixelSize: Int? = nil
    ) async throws -> PlatformImage {
        let key = CacheKey(url: url, maxPixelSize: maxPixelSize ?? 0)
        if let cached = cache.object(forKey: key.cacheIdentifier) { return cached }

        let task: Task<PlatformImage, any Error>
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            task = existing.task
        } else {
            task = Task<PlatformImage, any Error> { [session] in
                var request = URLRequest(url: url)
                // The same agent as every other request. Thumbnails used to go
                // out as the networking framework's own default, which is the
                // one request on the site that did not look like a browser.
                request.setValue(UserAgent.current, forHTTPHeaderField: "User-Agent")
                if let referer {
                    // The site serves media to its own pages; matching the
                    // referer keeps hotlink protection from turning thumbnails
                    // into 403s.
                    request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                }
                let (data, response) = try await session.data(for: request)
                // A refusal used to fall through to the decoder and come out
                // as "not an image", which hid what the server actually said.
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Self.log.error(
                        """
                        refused with \(http.statusCode, privacy: .public): \
                        \(url.host() ?? "?", privacy: .public)\(url.path(), privacy: .public), \
                        referer \(referer?.absoluteString ?? "none", privacy: .public)
                        """
                    )
                    throw LoaderError.refused(url, status: http.statusCode)
                }
                guard let image = ImageLoader.decode(data, maxPixelSize: maxPixelSize) else {
                    throw LoaderError.notAnImage(url)
                }
                return image
            }
            inFlight[key] = Load(task: task, waiters: 1)
        }

        // Cancelling the caller cancels the fetch, but only once nobody is left
        // waiting on it. A thumbnail scrolled past used to run to completion on
        // the radio with nothing to draw it, and a shared fetch must not be
        // taken away from the callers still waiting.
        return try await withTaskCancellationHandler {
            // A direct call: this closure runs on the loader's own executor, so
            // there is nothing to hop to.
            defer { release(key) }
            let image = try await task.value
            cache.setObject(image, forKey: key.cacheIdentifier, cost: image.approximateBytes)
            return image
        } onCancel: {
            Task { await cancelIfUnwanted(key) }
        }
    }

    /// The image if it is already in memory. Lets a view draw without a flash
    /// when scrolling back to something it just showed.
    public func cachedImage(at url: URL, maxPixelSize: Int? = nil) -> PlatformImage? {
        cache.object(forKey: CacheKey(url: url, maxPixelSize: maxPixelSize ?? 0).cacheIdentifier)
    }

    public func clearMemoryCache() {
        cache.removeAllObjects()
    }

    /// Notes that one caller has finished waiting.
    private func release(_ key: CacheKey) {
        guard var load = inFlight[key] else { return }
        load.waiters -= 1
        if load.waiters <= 0 {
            inFlight[key] = nil
        } else {
            inFlight[key] = load
        }
    }

    /// Drops one waiter and cancels the fetch if it was the last.
    private func cancelIfUnwanted(_ key: CacheKey) {
        guard var load = inFlight[key] else { return }
        load.waiters -= 1
        if load.waiters <= 0 {
            load.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = load
        }
    }

    /// Turns bytes into an image, at the size it will be drawn.
    ///
    /// `nonisolated` and `static` so it runs wherever the fetch does rather than
    /// hopping back to the loader, and so a test can call it directly.
    public nonisolated static func decode(_ data: Data, maxPixelSize: Int?) -> PlatformImage? {
        guard let maxPixelSize, maxPixelSize > 0 else {
            #if canImport(UIKit)
            // Still forced through the decoder here rather than left for the
            // render thread to do on first draw.
            return PlatformImage(data: data)?.preparingForDisplay()
            #else
            return PlatformImage(data: data)
            #endif
        }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
        else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary
            )
        else {
            // Not every format ImageIO can read will produce a thumbnail.
            return PlatformImage(data: data)
        }
        #if canImport(UIKit)
        return PlatformImage(cgImage: thumbnail)
        #else
        return PlatformImage(
            cgImage: thumbnail,
            size: CGSize(width: thumbnail.width, height: thumbnail.height)
        )
        #endif
    }
}

extension PlatformImage {
    /// Rough decoded size, used to weight the memory cache.
    var approximateBytes: Int {
        #if canImport(UIKit)
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
        #else
        return Int(size.width * size.height * 4)
        #endif
    }
}
