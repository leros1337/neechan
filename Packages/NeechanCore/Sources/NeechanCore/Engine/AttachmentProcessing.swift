import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What should be done to a file before it is uploaded.
public struct AttachmentProcessing: Sendable, Equatable {
    /// Appends random bytes so the file's hash differs from the original.
    ///
    /// 2ch rejects a file it has seen before with "similar file already
    /// uploaded"; changing the hash is how every client works around that.
    public var appendsUniqueHash: Bool
    /// Removes EXIF, GPS and the rest, which otherwise travel with the photo.
    public var stripsMetadata: Bool
    /// JPEG quality, 1 to 100, when the image should be re-encoded.
    public var reencodeQuality: Int?
    /// Percentage of the original dimensions, when it should be scaled down.
    public var scalePercent: Int?
    /// Replacement base name, without extension.
    public var renameTo: String?

    public init(
        appendsUniqueHash: Bool = false,
        stripsMetadata: Bool = false,
        reencodeQuality: Int? = nil,
        scalePercent: Int? = nil,
        renameTo: String? = nil
    ) {
        self.appendsUniqueHash = appendsUniqueHash
        self.stripsMetadata = stripsMetadata
        self.reencodeQuality = reencodeQuality
        self.scalePercent = scalePercent
        self.renameTo = renameTo
    }

    public static let none = AttachmentProcessing()

    public var changesContent: Bool {
        appendsUniqueHash || stripsMetadata || reencodeQuality != nil || scalePercent != nil
    }
}

/// Applies the per-file options before a post is sent.
public enum AttachmentProcessor {
    /// A file ready to upload.
    public struct Output: Sendable, Equatable {
        public var fileName: String
        public var mimeType: String
        public var data: Data
    }

    public static func process(
        data: Data,
        fileName: String,
        mimeType: String,
        options: AttachmentProcessing
    ) -> Output {
        var data = data
        var fileName = fileName
        var mimeType = mimeType

        // Re-encoding rebuilds the image from pixels, which also drops metadata,
        // so it runs first and makes a separate strip unnecessary.
        if options.reencodeQuality != nil || options.scalePercent != nil {
            if let encoded = reencode(
                data,
                quality: options.reencodeQuality ?? 85,
                scalePercent: options.scalePercent ?? 100
            ) {
                data = encoded
                fileName = (fileName as NSString).deletingPathExtension + ".jpg"
                mimeType = "image/jpeg"
            }
        } else if options.stripsMetadata {
            data = stripMetadata(from: data) ?? data
        }

        if let renameTo = options.renameTo, !renameTo.isEmpty {
            let ext = (fileName as NSString).pathExtension
            fileName = ext.isEmpty ? renameTo : "\(renameTo).\(ext)"
        }

        if options.appendsUniqueHash {
            data = appendingUniqueBytes(to: data)
        }

        return Output(fileName: fileName, mimeType: mimeType, data: data)
    }

    // MARK: Steps

    /// Appends bytes that change the file's hash without changing what it shows.
    ///
    /// Decoders stop at the end-of-image marker, so trailing bytes are ignored
    /// by every viewer while making the file unique to the server.
    static func appendingUniqueBytes(to data: Data) -> Data {
        var result = data
        var random = Data(count: 16)
        _ = random.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        result.append(random)
        return result
    }

    /// Rewrites the image without any metadata.
    static func stripMetadata(from data: Data) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source)
        else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        // Setting each property to null removes it rather than copying it over.
        let removals: [CFString: Any] = [
            kCGImagePropertyExifDictionary: kCFNull as Any,
            kCGImagePropertyGPSDictionary: kCFNull as Any,
            kCGImagePropertyTIFFDictionary: kCFNull as Any,
            kCGImagePropertyIPTCDictionary: kCFNull as Any,
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, removals as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Re-encodes as JPEG, optionally smaller.
    static func reencode(_ data: Data, quality: Int, scalePercent: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let clampedScale = max(1, min(100, scalePercent))
        let image: CGImage?
        if clampedScale < 100 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let longest = max(width, height)
            let target = max(1, longest * clampedScale / 100)
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: Double(max(1, min(100, quality))) / 100,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
