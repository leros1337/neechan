import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads animated images with ImageIO.
///
/// GIF and APNG are common on 2ch and neither `UIImage(data:)` nor SwiftUI's
/// `Image` animates them. ImageIO exposes the frames and their delays, which is
/// all a renderer needs and costs no extra dependency.
public enum AnimatedImageDecoder {
    /// One decoded frame.
    public struct Frame: Sendable {
        public let image: CGImage
        /// How long to show it. Never zero: browsers clamp very short delays.
        public let duration: TimeInterval
    }

    /// A decoded animation.
    public struct Animation: Sendable {
        public let frames: [Frame]
        /// How many times to repeat; zero means forever.
        public let loopCount: Int
        public let pixelSize: CGSize

        public var isAnimated: Bool { frames.count > 1 }
        public var totalDuration: TimeInterval { frames.reduce(0) { $0 + $1.duration } }
    }

    public enum DecodeError: Error {
        case notAnImage
        case noFrames
    }

    /// The shortest frame delay browsers honour. Files below it are slowed to
    /// match, which is what every other viewer does.
    private static let minimumFrameDuration: TimeInterval = 0.02
    private static let defaultFrameDuration: TimeInterval = 0.1

    /// Decodes every frame.
    ///
    /// - Parameter frameLimit: stops after this many frames, so a pathological
    ///   file cannot exhaust memory.
    public static func decode(_ data: Data, frameLimit: Int = 600) throws -> Animation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DecodeError.notAnImage
        }
        let count = min(CGImageSourceGetCount(source), frameLimit)
        guard count > 0 else { throw DecodeError.noFrames }

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(
                Frame(image: image, duration: frameDuration(of: source, at: index))
            )
        }
        guard let first = frames.first else { throw DecodeError.noFrames }

        return Animation(
            frames: frames,
            loopCount: loopCount(of: source),
            pixelSize: CGSize(width: first.image.width, height: first.image.height)
        )
    }

    /// True when the bytes hold more than one frame, without decoding them all.
    public static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    // MARK: Metadata

    private static func frameDuration(of source: CGImageSource, at index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
        else {
            return defaultFrameDuration
        }

        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary,
                    kCGImagePropertyWebPDictionary, kCGImagePropertyHEICSDictionary] {
            guard let dictionary = properties[key] as? [CFString: Any] else { continue }
            // The unclamped delay is the file's real intent; the clamped one has
            // already had the browser minimum applied by ImageIO.
            let unclamped = dictionary[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = dictionary[kCGImagePropertyGIFDelayTime] as? Double
            if let value = unclamped ?? clamped, value > 0 {
                return max(value, minimumFrameDuration)
            }
        }
        return defaultFrameDuration
    }

    private static func loopCount(of source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else {
            return 0
        }
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary,
                    kCGImagePropertyWebPDictionary] {
            if let dictionary = properties[key] as? [CFString: Any],
               let count = dictionary[kCGImagePropertyGIFLoopCount] as? Int {
                return count
            }
        }
        return 0
    }
}
