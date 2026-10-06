import CoreGraphics
import Foundation
import ImageIO
@testable import NeechanCore
import Testing
@testable import NeechanUI

/// The editor's behaviour, driven the way the canvas drives it: with points
/// on the screen.
@Suite("Image editor model", .serialized)
@MainActor
struct ImageEditorModelTests {
    /// A 400×300 photo shown in a 200×150 canvas, so one screen point is two
    /// pixels of the photo.
    private func makeModel(scalePercent: Int? = nil, width: Int = 400, height: Int = 300) async throws -> ImageEditorModel {
        let model = ImageEditorModel()
        await model.load(data: try Self.png(width: width, height: height), scalePercent: scalePercent)
        model.canvasBounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        return model
    }

    private func drag(_ model: ImageEditorModel, from start: CGPoint, to end: CGPoint, steps: Int = 4) {
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            model.dragChanged(start: start, location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        model.dragEnded(start: start, location: end)
    }

    private func tap(_ model: ImageEditorModel, at point: CGPoint) {
        model.dragChanged(start: point, location: point)
        model.dragEnded(start: point, location: point)
    }

    @Test("it opens ready, at the photo's size")
    func opens() async throws {
        let model = try await makeModel()
        #expect(model.phase == .ready)
        #expect(model.originalPixelSize == PixelSize(width: 400, height: 300))
        #expect(model.outputPixelSize == PixelSize(width: 400, height: 300))
        #expect(model.viewport == CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    @Test("an animation is refused")
    func refusesAnimation() async throws {
        let model = ImageEditorModel()
        await model.load(data: try Self.gif(), scalePercent: nil)
        #expect(model.phase == .failed)
    }

    @Test("it starts from the attachment's old scale")
    func legacyScale() async throws {
        let model = try await makeModel(scalePercent: 50)
        #expect(model.scalePercent == 50)
        #expect(model.outputPixelSize == PixelSize(width: 200, height: 150))
        #expect(!model.hasChanges)
    }

    @Test("an untouched editor finishes without writing")
    func untouched() async throws {
        let model = try await makeModel(scalePercent: 50)
        #expect(await model.finish() == .unchanged)
    }

    @Test("each finished stroke is one undo step")
    func strokeIsOneStep() async throws {
        let model = try await makeModel()
        drag(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100), steps: 10)
        drag(model, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 100, y: 10))
        #expect(model.edit.marks.count == 2)
        guard case .pen(let points, _, _) = model.edit.marks[0].kind else {
            Issue.record("not a pen stroke")
            return
        }
        // In the photo's own pixels: twice the screen's.
        #expect(points.first == CGPoint(x: 20, y: 20))
        #expect(points.last == CGPoint(x: 200, y: 200))

        model.undo()
        #expect(model.edit.marks.count == 1)
        model.undo()
        #expect(model.edit.marks.isEmpty)
        #expect(!model.canUndo)
        model.redo()
        #expect(model.edit.marks.count == 1)
    }

    @Test("a stroke's width follows the screen, not the photo's resolution")
    func widthFollowsScreen() async throws {
        let small = try await makeModel()
        small.size = 6
        drag(small, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))

        let large = try await makeModel(width: 1600, height: 1200)
        large.size = 6
        drag(large, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))

        guard case .pen(_, let smallWidth, _) = small.edit.marks.first?.kind,
              case .pen(_, let largeWidth, _) = large.edit.marks.first?.kind
        else {
            Issue.record("no strokes")
            return
        }
        #expect(smallWidth == 12)
        #expect(largeWidth == 48)
    }

    @Test("a drag the system cut short is kept, and the next one starts afresh")
    func interruptedDrag() async throws {
        let model = try await makeModel()
        // No end for the first drag: it was taken away mid-stroke.
        model.dragChanged(start: CGPoint(x: 10, y: 10), location: CGPoint(x: 40, y: 40))
        drag(model, from: CGPoint(x: 100, y: 10), to: CGPoint(x: 150, y: 60))

        #expect(model.edit.marks.count == 2)
        guard case .pen(let second, _, _) = model.edit.marks[1].kind else {
            Issue.record("not a pen stroke")
            return
        }
        #expect(second.first == CGPoint(x: 200, y: 20))
        #expect(model.activeMark == nil)
    }

    @Test("an arrow goes from where the drag began to where it ended, and a tap draws none")
    func arrow() async throws {
        let model = try await makeModel()
        model.tool = .arrow
        tap(model, at: CGPoint(x: 50, y: 50))
        #expect(model.edit.marks.isEmpty)

        drag(model, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70))
        guard case .arrow(let from, let to, _, _) = model.edit.marks.first?.kind else {
            Issue.record("no arrow")
            return
        }
        #expect(from == CGPoint(x: 20, y: 40))
        #expect(to == CGPoint(x: 220, y: 140))
    }

    @Test("turning, mirroring and cropping can each be undone")
    func orientationUndo() async throws {
        let model = try await makeModel()
        model.mode = .crop
        model.turn(clockwise: true)
        #expect(model.edit.quarterTurns == 1)
        model.mirror()
        #expect(model.edit.isMirrored)

        // The whole turned photo, 300×400, fits a 200×150 canvas at 0.375.
        let crop = try #require(model.cropRectInView)
        drag(model, from: CGPoint(x: crop.maxX, y: crop.maxY), to: CGPoint(x: crop.maxX - 30, y: crop.maxY - 30))
        #expect(model.edit.crop != model.edit.fullCrop)

        model.undo()
        #expect(model.edit.crop == model.edit.fullCrop)
        model.undo()
        #expect(!model.edit.isMirrored)
        model.undo()
        #expect(model.edit.quarterTurns == 0)
    }

    @Test("choosing an aspect fits the crop to it, and turning swaps it")
    func aspect() async throws {
        let model = try await makeModel()
        model.mode = .crop
        model.setAspect(.square)
        #expect(model.edit.crop.width == model.edit.crop.height)
        #expect(model.edit.crop.height == 300)

        model.setAspect(.sixteenNine)
        model.turn(clockwise: true)
        #expect(model.cropAspect == .nineSixteen)
    }

    @Test("a text-tool tap on a label edits it, and elsewhere places a new one")
    func labels() async throws {
        let model = try await makeModel()
        model.tool = .text

        tap(model, at: CGPoint(x: 100, y: 75))
        let placing = try #require(model.labelEditing)
        #expect(placing.isNew)
        #expect(placing.label.center == CGPoint(x: 200, y: 150))
        model.labelText = "hello"
        model.finishEditingLabel()
        #expect(model.edit.marks.count == 1)
        let id = try #require(model.edit.marks.first?.id)

        tap(model, at: CGPoint(x: 100, y: 75))
        let editing = try #require(model.labelEditing)
        #expect(editing.id == id)
        #expect(!editing.isNew)
        #expect(model.labelText == "hello")
        model.labelText = "bye"
        model.finishEditingLabel()
        #expect(model.edit.marks.count == 1)
        #expect(model.edit.marks.first?.label?.text == "bye")

        tap(model, at: CGPoint(x: 10, y: 10))
        #expect(model.labelEditing?.isNew == true)
    }

    @Test("a tap away from a label being typed only puts it down")
    func tapAwayFinishes() async throws {
        let model = try await makeModel()
        model.tool = .text
        tap(model, at: CGPoint(x: 100, y: 75))
        model.labelText = "first"

        tap(model, at: CGPoint(x: 20, y: 20))
        #expect(model.labelEditing == nil)
        #expect(model.edit.marks.compactMap(\.label?.text) == ["first"])
    }

    @Test("the preview is placed by what it was drawn from, so a stale one is never stretched")
    func previewFrame() async throws {
        let model = try await makeModel()
        try await waitForPreview(model)
        #expect(model.previewFrame == model.viewport)

        model.mode = .crop
        model.setAspect(.square)
        model.mode = .draw
        // The square crop now fills the height; the frame follows once drawn.
        try await waitForPreview(model)
        #expect(model.previewFrame == CGRect(x: 25, y: 0, width: 150, height: 150))
        #expect(model.previewFrame == model.viewport)
    }

    private func waitForPreview(_ model: ImageEditorModel) async throws {
        for _ in 0..<200 where !model.isPreviewCurrent {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isPreviewCurrent)
    }

    @Test("dragging a label moves it")
    func moveLabel() async throws {
        let model = try await makeModel()
        model.tool = .text
        tap(model, at: CGPoint(x: 100, y: 75))
        model.labelText = "move me"
        model.finishEditingLabel()

        drag(model, from: CGPoint(x: 100, y: 75), to: CGPoint(x: 120, y: 85))
        #expect(model.labelEditing == nil)
        #expect(model.edit.marks.first?.label?.center == CGPoint(x: 240, y: 170))
        model.undo()
        #expect(model.edit.marks.first?.label?.center == CGPoint(x: 200, y: 150))
    }

    @Test("an empty label is dropped when editing ends")
    func emptyLabel() async throws {
        let model = try await makeModel()
        model.tool = .text
        tap(model, at: CGPoint(x: 100, y: 75))
        model.labelText = "   "
        model.finishEditingLabel()
        #expect(model.edit.marks.isEmpty)
        #expect(!model.canUndo)

        tap(model, at: CGPoint(x: 100, y: 75))
        model.labelText = "kept"
        model.finishEditingLabel()
        tap(model, at: CGPoint(x: 100, y: 75))
        model.labelText = ""
        model.finishEditingLabel()
        #expect(model.edit.marks.isEmpty)
    }

    @Test("cancelling asks first only when something changed")
    func cancelling() async throws {
        let model = try await makeModel()
        #expect(!model.hasChanges)
        model.turn(clockwise: true)
        #expect(model.hasChanges)
        model.undo()
        #expect(!model.hasChanges)
    }

    @Test("a slider drag is one undo step")
    func slider() async throws {
        let model = try await makeModel()
        model.scaleEditingChanged(true)
        model.scalePercent = 90
        model.scalePercent = 70
        model.scalePercent = 50
        model.scaleEditingChanged(false)
        #expect(model.outputPixelSize == PixelSize(width: 200, height: 150))

        model.undo()
        #expect(model.scalePercent == 100)
        #expect(!model.canUndo)
    }

    @Test("the dimensions shown are the dimensions written")
    func dimensions() async throws {
        let model = try await makeModel()
        model.mode = .crop
        model.turn(clockwise: false)
        model.setAspect(.square)
        model.mode = .resize
        model.scalePercent = 37
        let shown = model.outputPixelSize

        guard case .edited(let output) = await model.finish() else {
            Issue.record("nothing was written")
            return
        }
        #expect(output.pixelSize == shown)
        #expect(output.mimeType == "image/png")
    }

    // MARK: Pictures

    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func gif() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
