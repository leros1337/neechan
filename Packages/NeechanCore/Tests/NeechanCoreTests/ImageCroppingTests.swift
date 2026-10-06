import CoreGraphics
import Foundation
import Testing
@testable import NeechanCore

@Suite("Image crop")
struct ImageCroppingTests {
    private let bounds = CGSize(width: 400, height: 300)
    private let start = CGRect(x: 100, y: 100, width: 100, height: 100)

    private func drag(
        _ handle: ImageCropHandle,
        by translation: CGSize,
        from rect: CGRect? = nil,
        aspect: CGFloat? = nil,
        minSide: CGFloat = 20
    ) -> CGRect {
        ImageCropping.drag(
            handle, from: rect ?? start, by: translation,
            bounds: bounds, aspect: aspect, minSide: minSide
        )
    }

    // MARK: Free

    @Test("a corner drag resizes from the opposite corner")
    func cornerDrag() {
        let rect = drag(.bottomRight, by: CGSize(width: 30, height: -20))
        #expect(rect == CGRect(x: 100, y: 100, width: 130, height: 80))

        let other = drag(.topLeft, by: CGSize(width: -50, height: 10))
        #expect(other == CGRect(x: 50, y: 110, width: 150, height: 90))
    }

    @Test("an edge drag moves only that edge")
    func edgeDrag() {
        #expect(drag(.left, by: CGSize(width: 20, height: 40)) == CGRect(x: 120, y: 100, width: 80, height: 100))
        #expect(drag(.bottom, by: CGSize(width: 99, height: 15)) == CGRect(x: 100, y: 100, width: 100, height: 115))
    }

    @Test("a crop never shrinks below its minimum side or leaves the image")
    func clamped() {
        let tiny = drag(.bottomRight, by: CGSize(width: -500, height: -500))
        #expect(tiny == CGRect(x: 100, y: 100, width: 20, height: 20))

        let huge = drag(.topLeft, by: CGSize(width: -500, height: -500))
        #expect(huge == CGRect(x: 0, y: 0, width: 200, height: 200))

        let wide = drag(.right, by: CGSize(width: 900, height: 0))
        #expect(wide.maxX == 400)
    }

    @Test("moving stops at the image's edges and keeps the size")
    func move() {
        let moved = drag(.move, by: CGSize(width: 1000, height: -1000))
        #expect(moved == CGRect(x: 300, y: 0, width: 100, height: 100))
    }

    // MARK: Aspect

    @Test("a locked aspect holds while a corner is dragged")
    func aspectCorner() {
        let rect = drag(.bottomRight, by: CGSize(width: 50, height: 0), aspect: 1)
        #expect(rect == CGRect(x: 100, y: 100, width: 150, height: 150))

        let wide = CGRect(x: 0, y: 0, width: 160, height: 90)
        let grown = drag(.bottomRight, by: CGSize(width: 0, height: 18), from: wide, aspect: 16 / 9)
        #expect(abs(grown.width / grown.height - 16 / 9) < 0.0001)
        #expect(abs(grown.height - 108) < 0.0001)
    }

    @Test("a locked aspect holds while an edge is dragged, keeping the crop centred")
    func aspectEdge() {
        let rect = drag(.right, by: CGSize(width: 20, height: 0), aspect: 1)
        #expect(rect == CGRect(x: 100, y: 90, width: 120, height: 120))
    }

    @Test("a locked aspect never pushes the crop past the image")
    func aspectClamped() {
        let rect = drag(.bottomRight, by: CGSize(width: 1000, height: 1000), aspect: 1)
        // 200 px is all there is below the crop's top edge.
        #expect(rect == CGRect(x: 100, y: 100, width: 200, height: 200))

        let edge = drag(.right, by: CGSize(width: 1000, height: 0), aspect: 1)
        #expect(edge.minY >= 0)
        #expect(edge.maxY <= 300)
        #expect(edge.maxX <= 400)
        #expect(abs(edge.width - edge.height) < 0.0001)
    }

    @Test("a locked aspect still keeps both sides above the minimum")
    func aspectMinimum() {
        let rect = drag(.bottomRight, by: CGSize(width: -1000, height: -1000), aspect: 2, minSide: 20)
        #expect(rect.height >= 20)
        #expect(abs(rect.width / rect.height - 2) < 0.0001)
    }

    @Test("choosing an aspect fits the largest rect of that shape around the current crop")
    func fitted() {
        let square = ImageCropping.fitted(aspect: 1, in: bounds, around: CGPoint(x: 350, y: 150))
        #expect(square == CGRect(x: 100, y: 0, width: 300, height: 300))

        let wide = ImageCropping.fitted(aspect: 16 / 9, in: bounds, around: CGPoint(x: 200, y: 150))
        #expect(wide.width == 400)
        #expect(abs(wide.height - 225) < 0.0001)
        #expect(abs(wide.midY - 150) < 0.0001)
    }

    @Test("each preset has the expected shape, and Original follows the turned picture")
    func ratios() throws {
        let turned = CGSize(width: 300, height: 400)
        #expect(ImageCropAspect.free.ratio(for: turned) == nil)
        #expect(ImageCropAspect.original.ratio(for: turned) == 0.75)
        #expect(ImageCropAspect.square.ratio(for: turned) == 1)
        let expected: [(ImageCropAspect, CGFloat)] = [
            (.fourThree, 4 / 3), (.threeFour, 3 / 4), (.sixteenNine, 16 / 9), (.nineSixteen, 9 / 16),
        ]
        for (aspect, ratio) in expected {
            let actual = try #require(aspect.ratio(for: turned))
            #expect(abs(actual - ratio) < 0.000_001)
        }
    }

    @Test("the minimum side never exceeds the picture")
    func minimumSide() {
        #expect(ImageCropping.minimumSide(for: CGSize(width: 4000, height: 3000)) == 32)
        #expect(ImageCropping.minimumSide(for: CGSize(width: 10, height: 6)) == 6)
    }

    // MARK: Handles

    @Test("handles are found within the touch tolerance, corners before edges")
    func handles() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(ImageCropHandle.hit(CGPoint(x: 95, y: 104), in: rect, tolerance: 20) == .topLeft)
        #expect(ImageCropHandle.hit(CGPoint(x: 310, y: 205), in: rect, tolerance: 20) == .bottomRight)
        #expect(ImageCropHandle.hit(CGPoint(x: 200, y: 92), in: rect, tolerance: 20) == .top)
        #expect(ImageCropHandle.hit(CGPoint(x: 112, y: 150), in: rect, tolerance: 20) == .left)
        #expect(ImageCropHandle.hit(CGPoint(x: 200, y: 150), in: rect, tolerance: 20) == .move)
        #expect(ImageCropHandle.hit(CGPoint(x: 10, y: 10), in: rect, tolerance: 20) == nil)
    }

    // MARK: Whole pixels

    @Test("a crop from the turned picture lands on whole pixels of the photo")
    func wholePixels() {
        let edit = ImageEdit(uprightSize: PixelSize(width: 400, height: 300)).turned(clockwise: true)
        let geometry = ImageEditGeometry(edit)
        let crop = ImageCropping.uprightCrop(
            fromOriented: CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50.7),
            geometry: geometry
        )
        // Oriented x 10.4…110.6 is upright y 189.4…289.6; oriented y 20.6…71.3 is
        // upright x 20.6…71.3. Each edge rounds to the nearest pixel.
        #expect(crop == CGRect(x: 21, y: 189, width: 50, height: 101))

        let outside = ImageCropping.uprightCrop(
            fromOriented: CGRect(x: -3, y: -3, width: 400, height: 500),
            geometry: geometry
        )
        #expect(outside == CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}
