import NeechanCore
import SwiftUI

/// The picture being edited, and the finger on it.
///
/// The picture itself is the model's preview, drawn by the same renderer as
/// the file. What is under the finger right now, and anything finished since
/// the last preview, is drawn on top in a `Canvas` until the preview catches up.
struct ImageEditorCanvas: View {
    let model: ImageEditorModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear

                if let preview = model.preview, let frame = model.previewFrame {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }

                MarkOverlay(
                    marks: model.overlayMarks,
                    transform: model.uprightToView,
                    scale: model.viewScale
                )

                if let crop = model.cropRectInView {
                    CropOverlay(frame: crop, picture: model.viewport)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(.rect)
            .gesture(drag)
            // Recomputed on every layout: on a Mac the window can be resized
            // with the editor open.
            .onChange(of: proxy.size, initial: true) { _, size in
                model.canvasBounds = CGRect(origin: .zero, size: size).insetBy(dx: 16, dy: 16)
            }
        }
        .deferringSystemGestures()
    }

    /// One drag for every tool; the model decides on touch-down what it does.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { model.dragChanged(start: $0.startLocation, location: $0.location) }
            .onEnded { model.dragEnded(start: $0.startLocation, location: $0.location) }
    }
}

/// Strokes not yet in the preview.
private struct MarkOverlay: View {
    let marks: [ImageEditMark]
    let transform: CGAffineTransform
    /// Screen points per pixel of the photo.
    let scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            for mark in marks {
                draw(mark, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ mark: ImageEditMark, in context: inout GraphicsContext) {
        switch mark.kind {
        case .pen(let points, let width, let color):
            context.stroke(
                path(ImageEditStrokes.smoothed(points)),
                with: .color(Color(color)),
                style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round)
            )
        case .arrow(let from, let to, let width, let color):
            let arrow = ImageEditStrokes.arrow(from: from, to: to, width: width)
            context.stroke(
                path(arrow.shaft),
                with: .color(Color(color)),
                style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round)
            )
            context.fill(path(arrow.head), with: .color(Color(color)))
        case .pixelate(let points, let width):
            // Where the brush has been; the blocks come with the next preview.
            context.stroke(
                path(ImageEditStrokes.smoothed(points)),
                with: .color(.white.opacity(0.35)),
                style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round)
            )
        case .label:
            break
        }
    }

    private func path(_ elements: [ImageEditPathElement]) -> Path {
        Path(ImageEditStrokes.path(elements)).applying(transform)
    }
}

/// The crop frame: the rest of the picture dimmed, a rule of thirds, and
/// corners to drag.
struct CropOverlay: View {
    let frame: CGRect
    let picture: CGRect

    var body: some View {
        Canvas { context, _ in
            var dimmed = Path()
            dimmed.addRect(picture)
            dimmed.addRect(frame)
            context.fill(dimmed, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

            var thirds = Path()
            for index in 1...2 {
                let x = frame.minX + frame.width * CGFloat(index) / 3
                let y = frame.minY + frame.height * CGFloat(index) / 3
                thirds.move(to: CGPoint(x: x, y: frame.minY))
                thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
                thirds.move(to: CGPoint(x: frame.minX, y: y))
                thirds.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            context.stroke(Path(frame), with: .color(.white), lineWidth: 1)

            let length = min(22, frame.width / 3, frame.height / 3)
            var corners = Path()
            let all: [(CGPoint, CGFloat, CGFloat)] = [
                (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
                (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
                (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
                (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
            ]
            for (corner, dx, dy) in all {
                corners.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
                corners.addLine(to: corner)
                corners.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            }
            context.stroke(
                corners,
                with: .color(.white),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }
}
