import Foundation
import ImageIO

/// Reads the metadata the gallery's info panel shows.
public enum EXIFReader {
    /// What an image file says about itself.
    public struct Metadata: Sendable, Equatable {
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var colorModel: String?
        public var depth: Int?
        public var hasAlpha: Bool?
        /// Camera make and model, when the file kept them.
        public var cameraMake: String?
        public var cameraModel: String?
        public var lens: String?
        public var software: String?
        public var capturedAt: String?
        public var exposureTime: Double?
        public var fNumber: Double?
        public var isoSpeed: Int?
        public var focalLength: Double?
        /// True when the file carries a location, which is worth flagging
        /// before the reader shares it.
        public var hasLocation: Bool = false

        public var isEmpty: Bool {
            self == Metadata(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }

        public init(pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    public static func read(_ data: Data) -> Metadata? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        var metadata = Metadata(
            pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int
        )
        metadata.colorModel = properties[kCGImagePropertyColorModel] as? String
        metadata.depth = properties[kCGImagePropertyDepth] as? Int
        metadata.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool
        metadata.hasLocation = properties[kCGImagePropertyGPSDictionary] != nil

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            metadata.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            metadata.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            metadata.software = tiff[kCGImagePropertyTIFFSoftware] as? String
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            metadata.lens = exif[kCGImagePropertyExifLensModel] as? String
            metadata.capturedAt = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            metadata.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
            metadata.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
            metadata.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                metadata.isoSpeed = isoValues.first
            }
        }
        return metadata
    }
}
