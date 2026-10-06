import CoreGraphics
import Foundation

/// One step of a drawn path, kept as a value so shapes can be compared in
/// tests and turned into either a Core Graphics or a SwiftUI path.
public enum ImageEditPathElement: Sendable, Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(to: CGPoint, control: CGPoint)
    case close
}

/// The shapes behind pen strokes, arrows and the pixelate brush.
public enum ImageEditStrokes {
    /// `points` with `point` added, unless it is too close to the last one to
    /// be worth keeping.
    public static func appending(_ point: CGPoint, to points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < minDistance {
            return points
        }
        return points + [point]
    }

    /// A freehand stroke as a smooth curve.
    ///
    /// Each touch point becomes the control point of a curve between the
    /// midpoints on either side of it, which takes the corners out of a line
    /// sampled at touch rate. The curve starts and ends exactly where the
    /// finger did; a single touch is a zero-length line, which a round cap
    /// draws as a dot.
    public static func smoothed(_ points: [CGPoint]) -> [ImageEditPathElement] {
        guard let first = points.first else { return [] }
        guard points.count > 2 else {
            return [.move(first), .line(points.last ?? first)]
        }
        var elements: [ImageEditPathElement] = [.move(first)]
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            elements.append(.quad(to: midpoint(control, next), control: control))
        }
        elements.append(.line(points[points.count - 1]))
        return elements
    }

    /// A straight arrow: a shaft to stroke and a triangular head to fill.
    ///
    /// The head is three widths long and three wide, as Telegram draws it. The
    /// shaft stops halfway into the head, where the head is still wider than
    /// the shaft's round cap, so the cap never pokes out past the point. Too
    /// short for a shaft, the arrow is all head; with no length at all it
    /// points right.
    public static func arrow(
        from start: CGPoint,
        to end: CGPoint,
        width: CGFloat
    ) -> (shaft: [ImageEditPathElement], head: [ImageEditPathElement]) {
        let length = hypot(end.x - start.x, end.y - start.y)
        let direction = length > 0
            ? CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
            : CGPoint(x: 1, y: 0)
        let normal = CGPoint(x: -direction.y, y: direction.x)

        let headLength = width * 3
        let halfBase = width * 1.5
        let base = CGPoint(x: end.x - direction.x * headLength, y: end.y - direction.y * headLength)
        let head: [ImageEditPathElement] = [
            .move(end),
            .line(CGPoint(x: base.x + normal.x * halfBase, y: base.y + normal.y * halfBase)),
            .line(CGPoint(x: base.x - normal.x * halfBase, y: base.y - normal.y * halfBase)),
            .close,
        ]

        let shaftStop = headLength / 2
        guard length > shaftStop else { return ([], head) }
        let shaftEnd = CGPoint(x: end.x - direction.x * shaftStop, y: end.y - direction.y * shaftStop)
        return ([.move(start), .line(shaftEnd)], head)
    }

    /// The side of a pixelation block, in the photo's own pixels.
    ///
    /// A 48th of the photo's longest side, and never under 8 px: coarse enough
    /// that a line of text under it becomes a row or two of flat colour, which
    /// is what keeps it from being read back by de-pixelating tools.
    public static func pixelBlock(for uprightSize: PixelSize) -> Int {
        max(8, Int((Double(uprightSize.longestSide) / 48).rounded()))
    }

    /// The elements as a Core Graphics path.
    public static func path(_ elements: [ImageEditPathElement]) -> CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .quad(let point, let control): path.addQuadCurve(to: point, control: control)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
