import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NeechanMedia

@Suite("Animated frames")
struct AnimatedFrameDecoderTests {
    /// A GIF with `frames` frames, each a solid colour, built in memory.
    private func gif(frames: Int, side: Int = 200, delay: Double = 0.1) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                output, UTType.gif.identifier as CFString, frames, nil
            )
        )
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        for index in 0..<frames {
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
            let shade = Double(index) / Double(max(1, frames))
            context.setFillColor(CGColor(red: shade, green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            )
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The whole point: a long animation can be sized and timed before a single
    /// frame is decoded.
    @Test("the shape of an animation is read without decoding any of it")
    func metadataNeedsNoFrames() throws {
        let data = try gif(frames: 12)

        let metadata = try AnimatedImageDecoder.metadata(data)

        #expect(metadata.frameCount == 12)
        #expect(metadata.durations.count == 12)
        #expect(metadata.isAnimated)
        #expect(metadata.loopCount == 0, "zero means forever")
        #expect(metadata.pixelSize == CGSize(width: 200, height: 200))
    }

    @Test("the shortest frame decides the rate the display link needs")
    func shortestFrame() throws {
        let metadata = try AnimatedImageDecoder.metadata(try gif(frames: 4, delay: 0.05))
        #expect(metadata.shortestFrameDuration == 0.05)
        #expect(AnimationFrameRate.hertz(forMinimumDelay: metadata.shortestFrameDuration) == 20)
    }

    @Test("a frame is decoded when it is asked for, at the size it will be drawn")
    func framesDecodeOnDemand() async throws {
        let decoder = try AnimatedFrameDecoder(data: try gif(frames: 6), maxPixelSize: 50)

        let frame = try #require(await decoder.frame(at: 0))

        #expect(max(frame.width, frame.height) <= 50)
        #expect(await decoder.metadata.frameCount == 6)
    }

    @Test("asking for the same frame twice gives the same image back")
    func framesAreKeptBriefly() async throws {
        let decoder = try AnimatedFrameDecoder(data: try gif(frames: 4), maxPixelSize: 50)

        let first = try #require(await decoder.frame(at: 1))
        let second = try #require(await decoder.frame(at: 1))

        #expect(first === second)
    }

    @Test("a frame that does not exist is nothing, rather than a crash")
    func outOfRangeFrames() async throws {
        let decoder = try AnimatedFrameDecoder(data: try gif(frames: 3), maxPixelSize: 50)

        #expect(await decoder.frame(at: 3) == nil)
        #expect(await decoder.frame(at: -1) == nil)
    }

    /// Holding every frame of a long animation is what this replaced.
    @Test("only a few frames are held at once")
    func oldFramesAreDropped() async throws {
        let decoder = try AnimatedFrameDecoder(
            data: try gif(frames: 20), maxPixelSize: 50, capacity: 3
        )

        let first = try #require(await decoder.frame(at: 0))
        for index in 1..<10 {
            _ = await decoder.frame(at: index)
        }
        let firstAgain = try #require(await decoder.frame(at: 0))

        #expect(first !== firstAgain, "the first frame was dropped and decoded again")
    }

    @Test("bytes that are not an image are refused")
    func rubbishIsRefused() {
        #expect(throws: (any Error).self) {
            _ = try AnimatedFrameDecoder(data: Data("nope".utf8), maxPixelSize: 50)
        }
    }
}
