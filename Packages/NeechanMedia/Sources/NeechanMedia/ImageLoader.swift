import Foundation
import NeechanAPI
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// Fetches and caches images.
///
/// Thumbnails are requested in bursts as a list scrolls, so identical requests
/// are coalesced: the second caller for a URL awaits the first one's task
/// instead of opening a second connection.
public actor ImageLoader {
    public static let shared = ImageLoader()

    public enum LoaderError: Error {
        case notAnImage(URL)
    }

    private let session: URLSession
    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: Task<PlatformImage, any Error>] = [:]

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
            self.session = URLSession(configuration: configuration)
        }
        cache.totalCostLimit = memoryLimitBytes
    }

    /// The image at `url`, from memory when it is already there.
    public func image(at url: URL, referer: URL? = nil) async throws -> PlatformImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<PlatformImage, any Error> { [session] in
            var request = URLRequest(url: url)
            // The same agent as every other request. Thumbnails used to go out
            // as the networking framework's own default, which is the one
            // request on the site that did not look like a browser.
            request.setValue(UserAgent.current, forHTTPHeaderField: "User-Agent")
            if let referer {
                // The site serves media to its own pages; matching the referer
                // keeps hotlink protection from turning thumbnails into 403s.
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }
            let (data, _) = try await session.data(for: request)
            guard let image = PlatformImage(data: data) else {
                throw LoaderError.notAnImage(url)
            }
            return image
        }
        inFlight[url] = task

        defer { inFlight[url] = nil }
        let image = try await task.value
        cache.setObject(image, forKey: url as NSURL, cost: image.approximateBytes)
        return image
    }

    /// The image if it is already in memory. Lets a view draw without a flash
    /// when scrolling back to something it just showed.
    public func cachedImage(at url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    public func clearMemoryCache() {
        cache.removeAllObjects()
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
