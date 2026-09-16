import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NeechanMedia

@Suite("Image decoding")
struct ImageDecodingTests {
    /// A PNG of the given size, built in memory so the test needs no fixture.
    private func png(side: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The thumbnail in a board grid is drawn at a couple of hundred pixels; the
    /// file behind it need not be decoded at its own size to get there.
    @Test("an image is decoded no larger than the size it will be drawn")
    func downsamples() throws {
        let data = try png(side: 400)

        let decoded = try #require(ImageLoader.decode(data, maxPixelSize: 100))

        #expect(max(decoded.size.width, decoded.size.height) <= 100)
    }

    @Test("asking for no particular size keeps the whole image")
    func fullSizeIsKept() throws {
        let data = try png(side: 120)

        let decoded = try #require(ImageLoader.decode(data, maxPixelSize: nil))

        #expect(max(decoded.size.width, decoded.size.height) == 120)
    }

    @Test("an image smaller than the size asked for is not stretched")
    func smallImagesAreLeftAlone() throws {
        let data = try png(side: 40)

        let decoded = try #require(ImageLoader.decode(data, maxPixelSize: 200))

        #expect(max(decoded.size.width, decoded.size.height) == 40)
    }

    @Test("bytes that are not an image decode to nothing")
    func rubbishIsRejected() {
        #expect(ImageLoader.decode(Data("not an image".utf8), maxPixelSize: 100) == nil)
    }
}
