import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why an edited picture could not be written.
public enum ImageEditError: Error, Sendable, Equatable {
    /// An animation, or not a picture.
    case notEditable
    case unreadable
    case renderFailed
    case encodeFailed
}

/// An edited picture, ready to stage in place of the original.
public struct ImageEditOutput: Sendable, Equatable {
    public var data: Data
    /// Without the dot.
    public var fileExtension: String
    public var mimeType: String
    public var pixelSize: PixelSize

    public init(data: Data, fileExtension: String, mimeType: String, pixelSize: PixelSize) {
        self.data = data
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.pixelSize = pixelSize
    }

    /// `name` with its extension swapped for the one this file was written as.
    public func fileName(replacingExtensionOf name: String) -> String {
        "\((name as NSString).deletingPathExtension).\(fileExtension)"
    }
}

/// Draws an edit, for the screen and for the file alike.
///
/// The preview is this same drawing at screen size, so what the reader sees
/// in the editor is what gets uploaded, text and pixelation included.
public enum ImageEditRenderer {
    /// The longest side to decode the photo at for writing: just the share of
    /// it the scale keeps.
    public static func decodeMaxPixelSize(for edit: ImageEdit) -> Int {
        let longest = Double(edit.uprightSize.longestSide)
        return max(1, Int((longest * Double(edit.scalePercent) / 100).rounded(.up)))
    }

    /// A preview canvas: `pixelScale` canvas pixels for each pixel of the
    /// turned picture, showing its crop or all of it.
    public static func canvasSize(for edit: ImageEdit, pixelScale: CGFloat, cropped: Bool) -> PixelSize {
        let geometry = ImageEditGeometry(edit)
        let region = cropped ? geometry.orientedCrop.size : geometry.orientedSize
        return PixelSize(
            width: max(1, Int((region.width * pixelScale).rounded())),
            height: max(1, Int((region.height * pixelScale).rounded()))
        )
    }

    /// The edit drawn over `base`, an upright decode of the photo at any
    /// resolution, onto a canvas of `canvasSize`.
    ///
    /// - Parameters:
    ///   - cropped: false to show the whole turned picture, for cropping.
    ///   - hiddenMark: a mark to leave out, such as the label being typed.
    ///   - opaque: drop the alpha channel, for a JPEG.
    public static func render(
        base: CGImage,
        edit: ImageEdit,
        canvasSize: PixelSize,
        cropped: Bool = true,
        hiding hiddenMark: UUID? = nil,
        opaque: Bool = false
    ) -> CGImage? {
        guard let context = makeContext(size: canvasSize, like: base, opaque: opaque) else { return nil }
        // y down, as everything in the edit is measured.
        context.translateBy(x: 0, y: CGFloat(canvasSize.height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high

        let geometry = ImageEditGeometry(edit)
        let toCanvas = geometry.uprightToCanvas(canvasSize: canvasSize.cgSize, cropped: cropped)
        let photo = CGRect(origin: .zero, size: edit.uprightSize.cgSize)

        context.saveGState()
        context.concatenate(toCanvas)
        draw(base, in: photo, context: context)

        // Made once, and only when something asks for it.
        var pixelated: CGImage?
        var hasPixelated = false
        let block = ImageEditStrokes.pixelBlock(for: edit.uprightSize)

        for mark in edit.marks where mark.id != hiddenMark {
            switch mark.kind {
            case .pen(let points, let width, let color):
                context.addPath(ImageEditStrokes.path(ImageEditStrokes.smoothed(points)))
                stroke(context, width: width, color: color.cgColor)

            case .arrow(let start, let end, let width, let color):
                let arrow = ImageEditStrokes.arrow(from: start, to: end, width: width)
                if !arrow.shaft.isEmpty {
                    context.addPath(ImageEditStrokes.path(arrow.shaft))
                    stroke(context, width: width, color: color.cgColor)
                }
                context.addPath(ImageEditStrokes.path(arrow.head))
                context.setFillColor(color.cgColor)
                context.fillPath()

            case .pixelate(let points, let width):
                if !hasPixelated {
                    pixelated = pixelate(base, uprightSize: edit.uprightSize, block: block)
                    hasPixelated = true
                }
                guard let tiles = pixelated else { continue }
                let brush = ImageEditStrokes.path(ImageEditStrokes.smoothed(points))
                    .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
                context.saveGState()
                context.addPath(brush)
                context.clip()
                // Hard edges between blocks: smoothing them would blur the
                // blocks back towards what they hide.
                context.interpolationQuality = .none
                draw(
                    tiles,
                    in: CGRect(
                        x: 0, y: 0,
                        width: CGFloat(tiles.width * block),
                        height: CGFloat(tiles.height * block)
                    ),
                    context: context
                )
                context.restoreGState()

            case .label(let label):
                // Letters are drawn on the canvas itself, so they stay upright
                // and unmirrored whatever was done to the photo.
                context.saveGState()
                context.concatenate(toCanvas.inverted())
                let scale = (hypot(toCanvas.a, toCanvas.b) + hypot(toCanvas.c, toCanvas.d)) / 2
                drawLabel(label, at: label.center.applying(toCanvas), scale: scale, context: context)
                context.restoreGState()
            }
        }
        context.restoreGState()
        return context.makeImage()
    }

    /// Writes the edited picture.
    ///
    /// PNG for screenshots and anything with transparency, JPEG for photos;
    /// see ``ImageEditSource/prefersLossless``. Nothing from the original's
    /// metadata is carried over: no location, no camera, no orientation, the
    /// pixels already being upright.
    public static func export(
        _ source: Data,
        edit: ImageEdit,
        jpegQuality: Double = 0.92
    ) throws(ImageEditError) -> ImageEditOutput {
        guard let info = ImageEditSource(data: source), info.isEditable else { throw .notEditable }
        guard let base = ImageEditSource.decodeUpright(source, maxPixelSize: decodeMaxPixelSize(for: edit)) else {
            throw .unreadable
        }

        let size = ImageEditGeometry(edit).outputPixelSize
        let lossless = info.prefersLossless
        guard let image = render(base: base, edit: edit, canvasSize: size, opaque: !lossless) else {
            throw .renderFailed
        }

        let type: UTType = lossless ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw .encodeFailed
        }
        let properties: [CFString: Any] = lossless
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .encodeFailed }

        return ImageEditOutput(
            data: output as Data,
            fileExtension: lossless ? "png" : "jpg",
            mimeType: lossless ? "image/png" : "image/jpeg",
            pixelSize: size
        )
    }

    // MARK: Drawing

    /// Keeps the photo's own colour space when it can be drawn into, so a
    /// wide-gamut photo is not squeezed into sRGB.
    private static func makeContext(size: PixelSize, like base: CGImage, opaque: Bool) -> CGContext? {
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let spaces = [base.colorSpace].compactMap { $0 }.filter { $0.model == .rgb } + [srgb]
        for space in spaces {
            if let context = CGContext(
                data: nil, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: alpha.rawValue
            ) {
                return context
            }
        }
        return nil
    }

    /// Draws an image the right way up in a y-down context.
    private static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func stroke(_ context: CGContext, width: CGFloat, color: CGColor) {
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.strokePath()
    }

    /// The photo shrunk to one pixel per block, on a grid anchored at its
    /// top-left corner, so blocks land on the same pixels at any preview size.
    private static func pixelate(_ base: CGImage, uprightSize: PixelSize, block: Int) -> CGImage? {
        let columns = (uprightSize.width + block - 1) / block
        let rows = (uprightSize.height + block - 1) / block
        guard let context = makeContext(size: PixelSize(width: columns, height: rows), like: base, opaque: false) else {
            return nil
        }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(rows))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: 1 / CGFloat(block), y: 1 / CGFloat(block))
        draw(base, in: CGRect(origin: .zero, size: uprightSize.cgSize), context: context)
        return context.makeImage()
    }

    /// Centred lines, filled in the label's colour over an outline in black or
    /// white, whichever stands out from it.
    private static func drawLabel(_ label: ImageEditLabel, at center: CGPoint, scale: CGFloat, context: CGContext) {
        let layout = ImageEditLabels.layout(of: label)
        let fill = label.color.cgColor
        let outline = label.color.luminance > 0.5
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: scale, y: scale)
        // Core Text draws for a y-up context; this puts its letters upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setLineJoin(.round)
        // The stroke straddles each letter's edge, so twice the width leaves
        // the full outline showing outside it.
        context.setLineWidth(layout.outline * 2)
        context.setStrokeColor(outline)
        context.setFillColor(fill)

        for mode in [CGTextDrawingMode.stroke, .fill] {
            context.setTextDrawingMode(mode)
            for (index, line) in layout.lines.enumerated() {
                context.textPosition = CGPoint(
                    x: -line.width / 2,
                    y: -layout.size.height / 2 + layout.outline + layout.ascent
                        + CGFloat(index) * layout.lineHeight
                )
                CTLineDraw(line.line, context)
            }
        }
        context.restoreGState()
    }
}
