import CoreGraphics

/// Where things land as an edit is applied.
///
/// Three spaces are involved. The *upright* photo is the picked file's pixels
/// after EXIF orientation. The *oriented* picture is that photo mirrored (if
/// asked), then turned clockwise. The *canvas* is what gets drawn: the oriented
/// picture's crop (or all of it, while cropping), scaled to the size asked for.
/// All three have y pointing down.
public struct ImageEditGeometry: Sendable {
    public let edit: ImageEdit
    /// Upright to oriented.
    public let orientation: CGAffineTransform

    public init(_ edit: ImageEdit) {
        self.edit = edit
        orientation = Self.orientation(of: edit)
    }

    /// The picture's size once mirrored and turned.
    public var orientedSize: CGSize {
        let size = edit.uprightSize.cgSize
        return edit.quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// The crop as the reader sees it, in the turned picture.
    public var orientedCrop: CGRect {
        orientedRect(fromUpright: edit.crop)
    }

    /// The size of the file the edit writes.
    public var outputPixelSize: PixelSize {
        let crop = orientedCrop.size
        let scale = Double(edit.scalePercent) / 100
        return PixelSize(
            width: max(1, Int((crop.width * scale).rounded())),
            height: max(1, Int((crop.height * scale).rounded()))
        )
    }

    // MARK: Mapping

    public func toOriented(_ point: CGPoint) -> CGPoint {
        point.applying(orientation)
    }

    public func toUpright(_ point: CGPoint) -> CGPoint {
        point.applying(orientation.inverted())
    }

    public func orientedRect(fromUpright rect: CGRect) -> CGRect {
        rect.applying(orientation).standardized
    }

    public func uprightRect(fromOriented rect: CGRect) -> CGRect {
        rect.applying(orientation.inverted()).standardized
    }

    /// Upright photo to a canvas of `canvasSize` showing the crop, or the
    /// whole turned picture when `cropped` is false.
    ///
    /// Each axis is scaled on its own, so the region fills the canvas exactly
    /// even after the output size has been rounded to whole pixels.
    public func uprightToCanvas(canvasSize: CGSize, cropped: Bool) -> CGAffineTransform {
        let region = cropped ? orientedCrop : CGRect(origin: .zero, size: orientedSize)
        guard region.width > 0, region.height > 0 else { return orientation }
        return orientation
            .concatenating(CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .concatenating(
                CGAffineTransform(
                    scaleX: canvasSize.width / region.width,
                    y: canvasSize.height / region.height
                )
            )
    }

    /// The largest rect of `content`'s shape that fits in `bounds`, centred.
    public static func fit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else {
            return CGRect(origin: CGPoint(x: bounds.midX, y: bounds.midY), size: .zero)
        }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Orientation

    /// The mirror, then the turns, as one transform.
    ///
    /// A clockwise turn of a `w`×`h` picture sends `(x, y)` to `(h − y, x)`:
    /// the top-left corner becomes the top-right one.
    private static func orientation(of edit: ImageEdit) -> CGAffineTransform {
        let width = CGFloat(edit.uprightSize.width)
        let height = CGFloat(edit.uprightSize.height)

        let mirror = edit.isMirrored
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
            : .identity

        let turn: CGAffineTransform
        switch ((edit.quarterTurns % 4) + 4) % 4 {
        case 1: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 2: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: turn = .identity
        }
        return mirror.concatenating(turn)
    }
}
