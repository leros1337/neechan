import CoreGraphics

/// Shapes the crop can be locked to.
public enum ImageCropAspect: String, CaseIterable, Sendable {
    case free
    /// The turned picture's own shape.
    case original
    case square
    case fourThree
    case threeFour
    case sixteenNine
    case nineSixteen

    /// Width over height, or nil when the crop is free.
    public func ratio(for orientedSize: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: orientedSize.height > 0 ? orientedSize.width / orientedSize.height : nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .threeFour: 3.0 / 4.0
        case .sixteenNine: 16.0 / 9.0
        case .nineSixteen: 9.0 / 16.0
        }
    }
}

/// The part of the crop frame a drag has taken hold of.
public enum ImageCropHandle: Sendable, Equatable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// The inside: the whole frame moves.
    case move

    /// What a touch at `point` takes hold of, or nil when it misses the frame.
    ///
    /// Corners win over edges, so the corner of a small frame is still easy to
    /// grab. On a frame too small for the tolerance, the tolerance shrinks so
    /// some of the inside is left for moving it.
    public static func hit(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> ImageCropHandle? {
        let reach = min(tolerance, min(rect.width, rect.height) / 3)

        let corners: [(ImageCropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        ]
        let nearestCorner = corners
            .map { ($0.0, hypot(point.x - $0.1.x, point.y - $0.1.y)) }
            .min { $0.1 < $1.1 }
        if let nearestCorner, nearestCorner.1 <= reach {
            return nearestCorner.0
        }

        let withinX = point.x >= rect.minX && point.x <= rect.maxX
        let withinY = point.y >= rect.minY && point.y <= rect.maxY
        let edges: [(ImageCropHandle, CGFloat, Bool)] = [
            (.top, abs(point.y - rect.minY), withinX),
            (.bottom, abs(point.y - rect.maxY), withinX),
            (.left, abs(point.x - rect.minX), withinY),
            (.right, abs(point.x - rect.maxX), withinY),
        ]
        let nearestEdge = edges
            .filter { $0.2 && $0.1 <= reach }
            .min { $0.1 < $1.1 }
        if let nearestEdge {
            return nearestEdge.0
        }

        return rect.contains(point) ? .move : nil
    }

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// Crop frame arithmetic, in the turned picture the reader sees.
public enum ImageCropping {
    /// The smallest side a crop may have: 32 px, or the picture itself if smaller.
    public static func minimumSide(for orientedSize: CGSize) -> CGFloat {
        min(32, min(orientedSize.width, orientedSize.height))
    }

    /// The frame after dragging `handle` by `translation` from where it was
    /// when the drag began.
    public static func drag(
        _ handle: ImageCropHandle,
        from rect: CGRect,
        by translation: CGSize,
        bounds: CGSize,
        aspect: CGFloat?,
        minSide: CGFloat
    ) -> CGRect {
        if handle == .move {
            let dx = clamp(translation.width, -rect.minX, bounds.width - rect.maxX)
            let dy = clamp(translation.height, -rect.minY, bounds.height - rect.maxY)
            return rect.offsetBy(dx: dx, dy: dy)
        }
        if let aspect, aspect > 0 {
            return dragLocked(handle, from: rect, by: translation, bounds: bounds, aspect: aspect, minSide: minSide)
        }

        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = clamp(rect.minX + translation.width, 0, maxX - minSide) }
        if handle.movesRight { maxX = clamp(rect.maxX + translation.width, minX + minSide, bounds.width) }
        if handle.movesTop { minY = clamp(rect.minY + translation.height, 0, maxY - minSide) }
        if handle.movesBottom { maxY = clamp(rect.maxY + translation.height, minY + minSide, bounds.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The largest rect of `aspect` inside `bounds`, as close to centred on
    /// `center` as the bounds allow.
    public static func fitted(aspect: CGFloat, in bounds: CGSize, around center: CGPoint) -> CGRect {
        let size: CGSize = bounds.width / bounds.height > aspect
            ? CGSize(width: bounds.height * aspect, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / aspect)
        let x = clamp(center.x - size.width / 2, 0, bounds.width - size.width)
        let y = clamp(center.y - size.height / 2, 0, bounds.height - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A frame from the turned picture as a crop of the photo: on whole
    /// pixels, and inside it.
    public static func uprightCrop(fromOriented rect: CGRect, geometry: ImageEditGeometry) -> CGRect {
        let upright = geometry.uprightRect(fromOriented: rect)
        let size = geometry.edit.uprightSize
        let minX = clamp(upright.minX.rounded(), 0, CGFloat(size.width) - 1)
        let minY = clamp(upright.minY.rounded(), 0, CGFloat(size.height) - 1)
        let maxX = clamp(upright.maxX.rounded(), minX + 1, CGFloat(size.width))
        let maxY = clamp(upright.maxY.rounded(), minY + 1, CGFloat(size.height))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Locked aspect

    private static func dragLocked(
        _ handle: ImageCropHandle,
        from rect: CGRect,
        by translation: CGSize,
        bounds: CGSize,
        aspect: CGFloat,
        minSide: CGFloat
    ) -> CGRect {
        // Both sides must stay above the minimum, so the width's floor is
        // whichever of the two binds.
        let minWidth = max(minSide, minSide * aspect)

        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            // The opposite corner stays put; the drag picks the size along
            // whichever axis it moved further, measured in width.
            let anchorX = handle.movesLeft ? rect.maxX : rect.minX
            let anchorY = handle.movesTop ? rect.maxY : rect.minY
            let dx = handle.movesLeft ? -translation.width : translation.width
            let dy = handle.movesTop ? -translation.height : translation.height
            let proposed = abs(dx) >= abs(dy * aspect)
                ? rect.width + dx
                : (rect.height + dy) * aspect

            let roomX = handle.movesLeft ? anchorX : bounds.width - anchorX
            let roomY = handle.movesTop ? anchorY : bounds.height - anchorY
            let width = clamp(proposed, minWidth, min(roomX, roomY * aspect))
            let height = width / aspect
            return CGRect(
                x: handle.movesLeft ? anchorX - width : anchorX,
                y: handle.movesTop ? anchorY - height : anchorY,
                width: width,
                height: height
            )

        case .left, .right:
            // The opposite edge stays put and the frame grows about its middle.
            let anchorX = handle == .left ? rect.maxX : rect.minX
            let proposed = rect.width + (handle == .left ? -translation.width : translation.width)
            let roomX = handle == .left ? anchorX : bounds.width - anchorX
            let roomY = 2 * min(rect.midY, bounds.height - rect.midY)
            let width = clamp(proposed, minWidth, min(roomX, roomY * aspect))
            let height = width / aspect
            return CGRect(
                x: handle == .left ? anchorX - width : anchorX,
                y: rect.midY - height / 2,
                width: width,
                height: height
            )

        case .top, .bottom:
            let anchorY = handle == .top ? rect.maxY : rect.minY
            let proposed = rect.height + (handle == .top ? -translation.height : translation.height)
            let roomY = handle == .top ? anchorY : bounds.height - anchorY
            let roomX = 2 * min(rect.midX, bounds.width - rect.midX)
            let height = clamp(proposed, minWidth / aspect, min(roomY, roomX / aspect))
            let width = height * aspect
            return CGRect(
                x: rect.midX - width / 2,
                y: handle == .top ? anchorY - height : anchorY,
                width: width,
                height: height
            )

        case .move:
            return rect
        }
    }

    /// `value` kept within `lower…upper`; when the range is empty, `upper` wins,
    /// so a frame never grows past the picture to honour its minimum.
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
