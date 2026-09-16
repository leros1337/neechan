import Foundation
import NeechanCore
import NeechanMedia

/// Fetches and decodes one gallery page's image, away from the main actor.
///
/// This used to be a method on the page's `View`, which made it main-actor
/// isolated: reading a cached file off the disk, sniffing it for animation and
/// decoding it all happened on the thread drawing the screen, and a large image
/// or a long GIF stalled it outright.
enum GalleryMediaLoader {
    /// What a page ended up with.
    enum Loaded: Sendable {
        case still(PlatformImage)
        /// The animation's shape, and where to get its frames from.
        case animated(AnimatedFrameDecoder, AnimatedImageDecoder.Metadata)
    }

    enum LoadError: Error {
        case notAnImage
    }

    /// The largest an animation's frames are decoded at.
    ///
    /// A still is kept at its own size, because the viewer zooms into it and a
    /// downsampled one would go soft under the reader's fingers. An animation is
    /// not examined that way, and a long one at full size is the largest thing
    /// this app ever holds, so it is bounded.
    static let animationPixelLimit = 2048

    /// Reads the file from the cache or the network, then decodes it.
    static func load(
        url: URL,
        referer: URL,
        fetcher: any MediaFetching
    ) async throws -> Loaded {
        let data: Data
        if let cached = await MediaCache.shared.cachedFile(for: url),
           let bytes = try? Data(contentsOf: cached) {
            data = bytes
        } else {
            // Full-size files are too large for URLCache to keep, so the gallery
            // uses its own disk cache: paging back to an image is instant and
            // costs no data.
            data = try await fetcher.data(url, referer: referer)
            try? await MediaCache.shared.store(data, for: url)
        }
        return try await decode(data)
    }

    /// Turns the bytes into something drawable, off the main actor.
    static func decode(_ data: Data) async throws -> Loaded {
        // An animated PNG or WebP is only detectable from its bytes, so the
        // decision is made here rather than from the file name.
        if AnimatedImageDecoder.isAnimated(data) {
            let decoder = try AnimatedFrameDecoder(
                data: data, maxPixelSize: animationPixelLimit
            )
            return .animated(decoder, await decoder.metadata)
        }
        // Full size, but decoded here rather than left undecoded for the render
        // thread to finish on first draw, which is what `UIImage(data:)` does.
        guard let image = ImageLoader.decode(data, maxPixelSize: nil) else {
            throw LoadError.notAnImage
        }
        return .still(image)
    }
}
