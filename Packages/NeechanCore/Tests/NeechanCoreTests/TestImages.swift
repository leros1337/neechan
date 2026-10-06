import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Small images built in code, so the processing and editing tests do not
/// need extra fixtures.
enum ImageFactory {
    static func png(width: Int, height: Int) throws -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try #require(context?.makeImage())
        return try encode(image, as: "public.png")
    }

    /// Red top-left, green top-right, blue bottom-left, white bottom-right.
    static func quadrants(width: Int, height: Int) throws -> CGImage {
        try draw(width: width, height: height) { context in
            let halfWidth = CGFloat(width) / 2
            let halfHeight = CGFloat(height) / 2
            let fills: [(CGRect, RGBA)] = [
                (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), .red),
                (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), .green),
                (CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), .blue),
                (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), .white),
            ]
            for (rect, color) in fills {
                context.setFillColor(color.cgColor)
                context.fill(rect)
            }
        }
    }

    static func solid(width: Int, height: Int, color: RGBA = .white) throws -> CGImage {
        try draw(width: width, height: height) { context in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Every pixel a different colour, so pixelation has something to flatten.
    static func gradient(width: Int, height: Int) throws -> CGImage {
        try draw(width: width, height: height) { context in
            for y in 0..<height {
                for x in 0..<width {
                    context.setFillColor(
                        CGColor(
                            srgbRed: CGFloat(x) / CGFloat(width),
                            green: CGFloat(y) / CGFloat(height),
                            blue: CGFloat((x * 7 + y * 13) % 255) / 255,
                            alpha: 1
                        )
                    )
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    /// An image with half its pixels see-through.
    static func halfTransparent(width: Int, height: Int) throws -> CGImage {
        try draw(width: width, height: height, opaque: false) { context in
            context.setFillColor(RGBA.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) / 2, height: CGFloat(height)))
        }
    }

    static func encode(
        _ image: CGImage,
        as type: String,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func animatedGIF(frames: Int, width: Int = 8, height: Int = 8) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString, frames, nil)
        )
        for index in 0..<frames {
            let image = try solid(width: width, height: height, color: index.isMultiple(of: 2) ? .red : .blue)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A context with y pointing down, as the editor thinks of pictures.
    private static func draw(
        width: Int,
        height: Int,
        opaque: Bool = true,
        _ body: (CGContext) -> Void
    ) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: (opaque
                    ? CGImageAlphaInfo.noneSkipLast
                    : CGImageAlphaInfo.premultipliedLast).rawValue
            )
        )
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        body(context)
        return try #require(context.makeImage())
    }
}

/// A pixel's colour, eight bits a channel.
struct RGBA: Equatable, CustomStringConvertible {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8 = 255

    static let red = RGBA(red: 255, green: 0, blue: 0)
    static let green = RGBA(red: 0, green: 255, blue: 0)
    static let blue = RGBA(red: 0, green: 0, blue: 255)
    static let white = RGBA(red: 255, green: 255, blue: 255)
    static let black = RGBA(red: 0, green: 0, blue: 0)

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255
        )
    }

    /// Within `tolerance` on every channel, which absorbs JPEG's rounding.
    func isClose(to other: RGBA, tolerance: Int = 40) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
            && abs(Int(alpha) - Int(other.alpha)) <= tolerance
    }

    var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }
}

/// Reads back what the processor or editor produced, without depending on
/// NeechanMedia.
enum EXIFReaderProbe {
    static func decodes(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard
            let properties = properties(of: data),
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    static func properties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func typeIdentifier(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    /// The file's pixels as stored, with no orientation applied.
    static func image(from data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}

/// Reads single pixels out of an image, counting rows from the top.
struct PixelProbe {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init(_ data: Data) throws {
        try self.init(EXIFReaderProbe.image(from: data))
    }

    subscript(x: Int, y: Int) -> RGBA {
        let offset = (y * width + x) * 4
        return RGBA(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }

    /// How many pixels in `rect` are close to `color`.
    func count(_ color: RGBA, in rect: CGRect, tolerance: Int = 60) -> Int {
        var count = 0
        for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) where self[x, y].isClose(to: color, tolerance: tolerance) {
                count += 1
            }
        }
        return count
    }
}
