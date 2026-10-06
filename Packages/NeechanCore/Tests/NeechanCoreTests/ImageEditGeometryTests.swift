import CoreGraphics
import Foundation
import Testing
@testable import NeechanCore

@Suite("Image edit geometry")
struct ImageEditGeometryTests {
    /// Every orientation an edit can be in: four turns, mirrored or not.
    static let orientations: [(turns: Int, mirrored: Bool)] = (0..<4).flatMap { turns in
        [(turns, false), (turns, true)]
    }

    private func edit(width: Int = 400, height: Int = 300) -> ImageEdit {
        ImageEdit(uprightSize: PixelSize(width: width, height: height))
    }

    @Test("an untouched edit outputs the photo at its own size")
    func untouched() {
        let edit = edit()
        #expect(edit.isIdentity)
        #expect(edit.crop == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(ImageEditGeometry(edit).outputPixelSize == PixelSize(width: 400, height: 300))
    }

    @Test("a quarter turn swaps width and height")
    func quarterTurnSwaps() {
        let turned = edit().turned(clockwise: true)
        let geometry = ImageEditGeometry(turned)
        #expect(geometry.orientedSize == CGSize(width: 300, height: 400))
        #expect(geometry.outputPixelSize == PixelSize(width: 300, height: 400))
        #expect(!turned.isIdentity)
    }

    @Test("four turns in either direction come back to where they started")
    func fourTurns() {
        var clockwise = edit()
        var counter = edit()
        for _ in 0..<4 {
            clockwise = clockwise.turned(clockwise: true)
            counter = counter.turned(clockwise: false)
        }
        #expect(clockwise.quarterTurns == 0)
        #expect(counter.quarterTurns == 0)
        #expect(edit().turned(clockwise: false).quarterTurns == 3)
    }

    @Test("the output is the crop scaled, rounded, and never below one pixel")
    func outputSize() {
        var edit = edit()
        edit.crop = CGRect(x: 10, y: 20, width: 101, height: 33)
        edit.scalePercent = 50
        // 50.5 rounds up, 16.5 rounds up.
        #expect(ImageEditGeometry(edit).outputPixelSize == PixelSize(width: 51, height: 17))

        edit.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        edit.scalePercent = 10
        #expect(ImageEditGeometry(edit).outputPixelSize == PixelSize(width: 1, height: 1))
    }

    @Test("a crop is reported in the turned picture's terms")
    func orientedCrop() {
        var edit = edit()
        edit.crop = CGRect(x: 0, y: 0, width: 100, height: 50)
        edit = edit.turned(clockwise: true)
        // The top-left corner of the photo is now its top-right.
        #expect(ImageEditGeometry(edit).orientedCrop == CGRect(x: 250, y: 0, width: 50, height: 100))
        #expect(ImageEditGeometry(edit).outputPixelSize == PixelSize(width: 50, height: 100))
    }

    @Test(
        "every turn and mirror maps a point out and back unchanged",
        arguments: orientations
    )
    func roundTrip(turns: Int, mirrored: Bool) {
        var edit = edit()
        edit.quarterTurns = turns
        edit.isMirrored = mirrored
        let geometry = ImageEditGeometry(edit)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 12.5, y: 280), CGPoint(x: 400, y: 300)] {
            let back = geometry.toUpright(geometry.toOriented(point))
            #expect(abs(back.x - point.x) < 0.0001)
            #expect(abs(back.y - point.y) < 0.0001)
        }
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(geometry.uprightRect(fromOriented: geometry.orientedRect(fromUpright: rect)) == rect)
    }

    @Test("one clockwise turn puts the top-left corner at the top-right")
    func clockwiseCorner() {
        let geometry = ImageEditGeometry(edit().turned(clockwise: true))
        #expect(geometry.toOriented(CGPoint(x: 0, y: 0)) == CGPoint(x: 300, y: 0))
        #expect(geometry.toOriented(CGPoint(x: 400, y: 0)) == CGPoint(x: 300, y: 400))
    }

    @Test("mirroring swaps left and right")
    func mirror() {
        let geometry = ImageEditGeometry(edit().mirroredAsSeen())
        #expect(geometry.toOriented(CGPoint(x: 0, y: 10)) == CGPoint(x: 400, y: 10))
    }

    @Test(
        "mirroring flips what is seen left to right, whatever the turn",
        arguments: orientations
    )
    func mirrorAsSeen(turns: Int, mirrored: Bool) {
        var edit = edit()
        edit.quarterTurns = turns
        edit.isMirrored = mirrored
        let before = ImageEditGeometry(edit)
        let after = ImageEditGeometry(edit.mirroredAsSeen())

        #expect(after.orientedSize == before.orientedSize)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 250), CGPoint(x: 400, y: 120)] {
            let seen = before.toOriented(point)
            let flipped = after.toOriented(point)
            #expect(abs(flipped.x - (before.orientedSize.width - seen.x)) < 0.0001)
            #expect(abs(flipped.y - seen.y) < 0.0001)
        }
    }

    @Test("turning and mirroring keep the same part of the photo cropped")
    func cropSurvivesOrientation() {
        var edit = edit()
        edit.crop = CGRect(x: 40, y: 30, width: 120, height: 90)
        #expect(edit.turned(clockwise: true).crop == edit.crop)
        #expect(edit.mirroredAsSeen().crop == edit.crop)
    }

    @Test("the output transform puts the crop's corner at the canvas origin and fills it")
    func outputTransform() {
        var edit = edit()
        edit.crop = CGRect(x: 100, y: 50, width: 200, height: 100)
        edit.scalePercent = 50
        let geometry = ImageEditGeometry(edit)
        let transform = geometry.uprightToCanvas(canvasSize: CGSize(width: 100, height: 50), cropped: true)
        #expect(CGPoint(x: 100, y: 50).applying(transform) == .zero)
        #expect(CGPoint(x: 300, y: 150).applying(transform) == CGPoint(x: 100, y: 50))

        // Uncropped, the whole turned picture fills the canvas instead.
        let whole = geometry.uprightToCanvas(canvasSize: CGSize(width: 200, height: 150), cropped: false)
        #expect(CGPoint(x: 400, y: 300).applying(whole) == CGPoint(x: 200, y: 150))
    }

    @Test("fitting keeps the aspect and centres the picture")
    func fit() {
        let fitted = ImageEditGeometry.fit(
            CGSize(width: 400, height: 200), in: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        #expect(fitted == CGRect(x: 0, y: 50, width: 200, height: 100))
    }
}
