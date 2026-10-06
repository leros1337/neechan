import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the editor needs to know about a picked file before opening it.
public struct ImageEditSource: Sendable, Equatable {
    /// The size once the photo's EXIF orientation is applied.
    public let uprightSize: PixelSize
    public let frameCount: Int
    public let hasAlpha: Bool
    public let typeIdentifier: String

    /// Reads the file's header; nil when it is not a picture at all.
    public init?(data: Data) {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?,
            UTType(type)?.conforms(to: .image) == true,
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else {
            return nil
        }
        // Orientations 5 to 8 store the photo on its side.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        uprightSize = (5...8).contains(orientation)
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
        frameCount = CGImageSourceGetCount(source)
        hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        typeIdentifier = type
    }

    /// A still picture. Editing an animation would keep only its first frame.
    public var isEditable: Bool {
        frameCount == 1
    }

    /// Whether the edited file should stay lossless.
    ///
    /// Screenshots and drawings come as PNG or GIF, where JPEG would smear the
    /// text and lines the reader is drawing attention to; and only PNG keeps
    /// transparency. Everything else is a photo, which JPEG suits.
    public var prefersLossless: Bool {
        hasAlpha
            || UTType(typeIdentifier)?.conforms(to: .png) == true
            || UTType(typeIdentifier)?.conforms(to: .gif) == true
    }

    /// The picture the right way up, no larger than `maxPixelSize` on its
    /// longest side, or at full size.
    ///
    /// Decoding straight to the size needed keeps a 48-megapixel photo from
    /// costing 200 MB when only a fraction of it will be written.
    public static func decodeUpright(_ data: Data, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            return nil
        }
        let longest = maxPixelSize ?? ImageEditSource(data: data)?.uprightSize.longestSide ?? 0
        guard longest > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ] as CFDictionary)
    }
}
