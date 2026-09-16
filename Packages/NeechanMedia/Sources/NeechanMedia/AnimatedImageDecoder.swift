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
    /// Everything about an animation except its pixels.
    ///
    /// Read without creating a single frame, so a two-hundred-frame GIF can be
    /// laid out and timed before any of it is decoded.
    public struct Metadata: Sendable, Equatable {
        public let frameCount: Int
        /// How long each frame is shown. Never zero.
        public let durations: [TimeInterval]
        /// How many times to repeat; zero means forever.
        public let loopCount: Int
        public let pixelSize: CGSize

        public var isAnimated: Bool { frameCount > 1 }
        public var totalDuration: TimeInterval { durations.reduce(0, +) }
        /// The shortest frame, which is the rate the display link needs.
        public var shortestFrameDuration: TimeInterval {
            durations.min() ?? AnimatedImageDecoder.defaultFrameDuration
        }
    }

    public enum DecodeError: Error {
        case notAnImage
        case noFrames
    }

    /// The shortest frame delay browsers honour. Files below it are slowed to
    /// match, which is what every other viewer does.
    private static let minimumFrameDuration: TimeInterval = 0.02
    static let defaultFrameDuration: TimeInterval = 0.1

    /// Reads the frame count, timings and size without decoding any pixels.
    public static func metadata(_ data: Data, frameLimit: Int = 600) throws -> Metadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DecodeError.notAnImage
        }
        return try metadata(of: source, frameLimit: frameLimit)
    }

    static func metadata(of source: CGImageSource, frameLimit: Int) throws -> Metadata {
        let count = min(CGImageSourceGetCount(source), frameLimit)
        guard count > 0 else { throw DecodeError.noFrames }

        let durations = (0..<count).map { frameDuration(of: source, at: $0) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        return Metadata(
            frameCount: count,
            durations: durations,
            loopCount: loopCount(of: source),
            pixelSize: CGSize(width: width, height: height)
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
