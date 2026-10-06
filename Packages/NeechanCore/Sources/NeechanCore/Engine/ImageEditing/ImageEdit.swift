import CoreGraphics
import Foundation

/// A width and height in whole pixels.
public struct PixelSize: Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    public var longestSide: Int {
        max(width, height)
    }
}

/// Everything the reader has done to a picture in the editor, as a value.
///
/// Nothing here touches pixels. The photo stays as it was picked, and the edit
/// is applied once, through a single transform, when the file is written. That
/// is what lets a crop or a turn come after the drawing without the drawing
/// drifting off the thing it was drawn on.
///
/// Positions are in the *upright* photo: its own pixels, after any EXIF
/// orientation, with y pointing down. The picture the reader sees is that photo
/// mirrored (if asked), then turned clockwise a number of quarter turns; see
/// ``ImageEditGeometry`` for the mapping.
public struct ImageEdit: Sendable, Equatable {
    /// The photo's size once its EXIF orientation is applied.
    public let uprightSize: PixelSize
    /// The part of the photo that is kept, in upright pixels, on whole pixels.
    ///
    /// Kept in the upright photo rather than in the turned picture, so turning
    /// or mirroring keeps the same part of the photo.
    public var crop: CGRect
    /// Clockwise quarter turns, 0 to 3, applied after the mirror.
    public var quarterTurns: Int
    /// Whether the upright photo is flipped left to right before turning.
    public var isMirrored: Bool
    /// Percentage of the cropped size to write, 10 to 100.
    public var scalePercent: Int
    /// Drawing, in the order it was made.
    public var marks: [ImageEditMark]

    public static let scaleRange = 10...100

    public init(uprightSize: PixelSize, scalePercent: Int = 100) {
        self.uprightSize = uprightSize
        crop = CGRect(origin: .zero, size: uprightSize.cgSize)
        quarterTurns = 0
        isMirrored = false
        self.scalePercent = min(max(scalePercent, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        marks = []
    }

    /// The whole photo, as a crop.
    public var fullCrop: CGRect {
        CGRect(origin: .zero, size: uprightSize.cgSize)
    }

    /// Whether writing this edit would give back the photo as it was.
    public var isIdentity: Bool {
        crop == fullCrop && quarterTurns == 0 && !isMirrored && scalePercent == 100 && marks.isEmpty
    }

    /// The same edit turned a quarter further.
    public func turned(clockwise: Bool) -> ImageEdit {
        var copy = self
        copy.quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        return copy
    }

    /// The same edit flipped left to right *as the reader sees it*.
    ///
    /// Toggling the mirror alone would flip a picture that has been turned once
    /// upside down instead, because the mirror applies before the turn. A flip
    /// after a turn is the opposite turn after a flip, so the turn is reversed
    /// along with it.
    public func mirroredAsSeen() -> ImageEdit {
        var copy = self
        copy.isMirrored.toggle()
        copy.quarterTurns = (4 - quarterTurns) % 4
        return copy
    }
}

/// One thing drawn on the picture.
public struct ImageEditMark: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var kind: Kind

    public enum Kind: Sendable, Equatable {
        /// A freehand line.
        case pen(points: [CGPoint], width: CGFloat, color: ThemeColor)
        /// A straight line with a head at its end.
        case arrow(from: CGPoint, to: CGPoint, width: CGFloat, color: ThemeColor)
        /// A freehand brush that pixelates the photo under it.
        case pixelate(points: [CGPoint], width: CGFloat)
        /// Text that always reads upright.
        case label(ImageEditLabel)
    }

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public var label: ImageEditLabel? {
        if case .label(let label) = kind { return label }
        return nil
    }
}

/// Text placed on the picture.
///
/// Its centre and size are in the upright photo, so it moves with the spot it
/// labels and shrinks when the picture does; its letters are always drawn
/// upright and never mirrored, so it can never end up sideways or backwards.
public struct ImageEditLabel: Sendable, Equatable {
    public var text: String
    public var center: CGPoint
    public var fontSize: CGFloat
    public var color: ThemeColor

    public init(text: String, center: CGPoint, fontSize: CGFloat, color: ThemeColor) {
        self.text = text
        self.center = center
        self.fontSize = fontSize
        self.color = color
    }
}

extension ThemeColor {
    /// The colour for drawing with Core Graphics.
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}
