import CoreGraphics
import Foundation
import ImageIO

/// Decodes an animation's frames as they are needed.
///
/// Decoding every frame up front costs a spike of work when a file is opened
/// and then holds the whole animation in memory for as long as the page exists:
/// a three-hundred-frame GIF at its own size is hundreds of megabytes once it
/// has looped once. Frames here are produced on demand, at the size they will
/// actually be drawn, and only a few are kept.
///
/// An actor because `CGImageSource` is not safe to use from two places at once.
public actor AnimatedFrameDecoder {
    public let metadata: AnimatedImageDecoder.Metadata

    private let source: CGImageSource
    private let maxPixelSize: Int?
    /// Decoded frames, keyed by index.
    private var frames: [Int: CGImage] = [:]
    /// Indices in the order they were decoded, oldest first.
    private var order: [Int] = []
    /// How many frames to keep. Enough for the one on screen, the one being
    /// prefetched and a little slack for a loop turning over.
    private let capacity: Int

    public init(data: Data, maxPixelSize: Int? = nil, frameLimit: Int = 600, capacity: Int = 6) throws {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else {
            throw AnimatedImageDecoder.DecodeError.notAnImage
        }
        self.source = source
        self.metadata = try AnimatedImageDecoder.metadata(of: source, frameLimit: frameLimit)
        self.maxPixelSize = maxPixelSize
        self.capacity = max(2, capacity)
    }

    /// The frame at `index`, decoding it if it is not already in hand.
    public func frame(at index: Int) -> CGImage? {
        guard index >= 0, index < metadata.frameCount else { return nil }
        if let held = frames[index] { return held }

        guard let image = makeFrame(at: index) else { return nil }
        frames[index] = image
        order.append(index)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            frames[oldest] = nil
        }
        return image
    }

    private func makeFrame(at index: Int) -> CGImage? {
        guard let maxPixelSize, maxPixelSize > 0 else {
            return CGImageSourceCreateImageAtIndex(
                source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, index, nil)
    }
}
