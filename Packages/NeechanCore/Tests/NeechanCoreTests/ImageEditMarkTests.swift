import CoreGraphics
import Foundation
import Testing
@testable import NeechanCore

@Suite("Image marks")
struct ImageEditMarkTests {
    private let red = ThemeColor(red: 1, green: 0, blue: 0)

    // MARK: Strokes

    @Test("a single touch becomes a dot")
    func dot() {
        let point = CGPoint(x: 5, y: 7)
        #expect(ImageEditStrokes.smoothed([point]) == [.move(point), .line(point)])
        #expect(ImageEditStrokes.smoothed([]).isEmpty)
    }

    @Test("a stroke curves through the midpoints and ends on its last point")
    func smoothing() {
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10),
        ]
        #expect(ImageEditStrokes.smoothed(points) == [
            .move(CGPoint(x: 0, y: 0)),
            .quad(to: CGPoint(x: 10, y: 5), control: CGPoint(x: 10, y: 0)),
            .quad(to: CGPoint(x: 15, y: 10), control: CGPoint(x: 10, y: 10)),
            .line(CGPoint(x: 20, y: 10)),
        ])
    }

    @Test("points closer than the threshold are dropped")
    func thinning() {
        var points = ImageEditStrokes.appending(CGPoint(x: 0, y: 0), to: [], minDistance: 2)
        points = ImageEditStrokes.appending(CGPoint(x: 1, y: 1), to: points, minDistance: 2)
        points = ImageEditStrokes.appending(CGPoint(x: 3, y: 0), to: points, minDistance: 2)
        #expect(points == [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0)])
    }

    // MARK: Arrows

    @Test("an arrow's head points at its end and is three widths long")
    func arrowHead() throws {
        let arrow = ImageEditStrokes.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), width: 4)
        guard case .move(let tip) = try #require(arrow.head.first),
              case .line(let left) = arrow.head[1],
              case .line(let right) = arrow.head[2]
        else {
            Issue.record("the head is not a triangle: \(arrow.head)")
            return
        }
        #expect(tip == CGPoint(x: 100, y: 0))
        #expect(arrow.head.last == .close)
        // The base is 12 back from the tip and 6 either side of the line.
        #expect(abs(left.x - 88) < 0.0001 && abs(abs(left.y) - 6) < 0.0001)
        #expect(abs(right.x - 88) < 0.0001 && abs(left.y + right.y) < 0.0001)
    }

    @Test("the shaft stops short of the tip so its cap never shows")
    func arrowShaft() {
        let arrow = ImageEditStrokes.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 100), width: 4)
        #expect(arrow.shaft == [.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 0, y: 94))])
    }

    @Test("a very short arrow still draws a whole head")
    func shortArrow() {
        let arrow = ImageEditStrokes.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 10), width: 4)
        #expect(arrow.shaft.isEmpty)
        #expect(arrow.head.count == 4)

        let still = ImageEditStrokes.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10), width: 4)
        #expect(still.head.count == 4)
    }

    // MARK: Pixelation

    @Test("pixel blocks are at least 8 px and grow with the photo")
    func pixelBlock() {
        #expect(ImageEditStrokes.pixelBlock(for: PixelSize(width: 100, height: 60)) == 8)
        #expect(ImageEditStrokes.pixelBlock(for: PixelSize(width: 3000, height: 4800)) == 100)
    }

    // MARK: Labels

    private func label(_ text: String, at center: CGPoint = CGPoint(x: 200, y: 150), size: CGFloat = 20) -> ImageEditLabel {
        ImageEditLabel(text: text, center: center, fontSize: size, color: red)
    }

    @Test("a label's box grows with its text, its lines and its size")
    func labelSize() {
        let short = ImageEditLabels.size(of: label("ab"))
        let long = ImageEditLabels.size(of: label("abcdef"))
        let twoLines = ImageEditLabels.size(of: label("ab\nab"))
        let bigger = ImageEditLabels.size(of: label("ab", size: 40))

        #expect(long.width > short.width)
        #expect(twoLines.height > short.height * 1.5)
        #expect(abs(twoLines.width - short.width) < 0.5)
        #expect(bigger.width > short.width * 1.8)
    }

    @Test("a label keeps its box shape after a quarter turn and follows its spot")
    func labelTurned() {
        let mark = ImageEditMark(kind: .label(label("hello", at: CGPoint(x: 10, y: 20))))
        var edit = ImageEdit(uprightSize: PixelSize(width: 400, height: 300))
        edit.marks = [mark]
        let upright = ImageEditLabels.frame(of: label("hello", at: CGPoint(x: 10, y: 20)), geometry: ImageEditGeometry(edit))

        let turnedEdit = edit.turned(clockwise: true)
        let turnedGeometry = ImageEditGeometry(turnedEdit)
        let turned = ImageEditLabels.frame(of: label("hello", at: CGPoint(x: 10, y: 20)), geometry: turnedGeometry)

        #expect(turned.size == upright.size)
        let center = turnedGeometry.toOriented(CGPoint(x: 10, y: 20))
        #expect(abs(turned.midX - center.x) < 0.0001)
        #expect(abs(turned.midY - center.y) < 0.0001)
    }

    @Test("a tap inside a label finds it, topmost first")
    func labelHit() {
        let lower = ImageEditMark(kind: .label(label("underneath", at: CGPoint(x: 200, y: 150))))
        let upper = ImageEditMark(kind: .label(label("on top", at: CGPoint(x: 205, y: 150))))
        let stroke = ImageEditMark(kind: .pen(points: [CGPoint(x: 200, y: 150)], width: 50, color: red))
        var edit = ImageEdit(uprightSize: PixelSize(width: 400, height: 300))
        edit.marks = [lower, upper, stroke]

        #expect(ImageEditLabels.hit(CGPoint(x: 203, y: 150), in: edit) == upper.id)
        #expect(ImageEditLabels.hit(CGPoint(x: 10, y: 10), in: edit) == nil)
    }
}

@Suite("Edit history")
struct EditHistoryTests {
    @Test("undo restores the previous state and redo brings it back")
    func undoRedo() {
        var history = EditHistory(1)
        history.record(2)
        history.record(3)
        #expect(history.canUndo && !history.canRedo)

        history.undo()
        #expect(history.current == 2)
        history.undo()
        #expect(history.current == 1)
        #expect(!history.canUndo)
        history.undo()
        #expect(history.current == 1)

        history.redo()
        history.redo()
        #expect(history.current == 3)
        #expect(!history.canRedo)
    }

    @Test("a change after an undo clears redo")
    func branchClearsRedo() {
        var history = EditHistory(1)
        history.record(2)
        history.undo()
        history.record(5)
        #expect(!history.canRedo)
        #expect(history.current == 5)
        history.undo()
        #expect(history.current == 1)
    }

    @Test("recording an unchanged state adds nothing")
    func unchanged() {
        var history = EditHistory(1)
        history.record(1)
        #expect(!history.canUndo)
    }

    @Test("history drops the oldest step past its capacity")
    func capacity() {
        var history = EditHistory(0, capacity: 3)
        for value in 1...5 { history.record(value) }
        history.undo()
        history.undo()
        history.undo()
        #expect(history.current == 2)
        #expect(!history.canUndo)
    }
}
