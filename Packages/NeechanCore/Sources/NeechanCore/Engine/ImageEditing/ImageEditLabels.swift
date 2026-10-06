import CoreGraphics
import CoreText
import Foundation

/// How text placed on a picture is laid out.
///
/// Measured with Core Text, the same as it is drawn, so the box the editor
/// hit-tests is the box the file gets.
public enum ImageEditLabels {
    /// The label's box: its widest line and all its lines, plus the outline.
    public static func size(of label: ImageEditLabel) -> CGSize {
        layout(of: label).size
    }

    /// Where the label sits in the turned picture.
    ///
    /// Its centre follows the spot it was placed on; its box keeps its shape,
    /// because the letters are always drawn upright.
    public static func frame(of label: ImageEditLabel, geometry: ImageEditGeometry) -> CGRect {
        let center = geometry.toOriented(label.center)
        let size = size(of: label)
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The topmost label under a point in the turned picture.
    public static func hit(_ orientedPoint: CGPoint, in edit: ImageEdit, padding: CGFloat = 0) -> UUID? {
        let geometry = ImageEditGeometry(edit)
        for mark in edit.marks.reversed() {
            guard let label = mark.label else { continue }
            if frame(of: label, geometry: geometry).insetBy(dx: -padding, dy: -padding).contains(orientedPoint) {
                return mark.id
            }
        }
        return nil
    }

    /// The outline's width either side of the letters' edges.
    public static func outlineWidth(for fontSize: CGFloat) -> CGFloat {
        fontSize * 0.12
    }

    /// A label's lines ready to draw, all at its own font size.
    struct Layout {
        var lines: [(line: CTLine, width: CGFloat)]
        var ascent: CGFloat
        var lineHeight: CGFloat
        var outline: CGFloat
        var size: CGSize
    }

    static func layout(of label: ImageEditLabel) -> Layout {
        let font = font(size: label.fontSize)
        // The colour comes from the context, so the outline and the fill can
        // be drawn from the same lines.
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: kCFBooleanTrue as Any,
        ] as CFDictionary

        let lines = label.text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { text -> (line: CTLine, width: CGFloat) in
                let string = CFAttributedStringCreate(nil, String(text) as CFString, attributes)!
                let line = CTLineCreateWithAttributedString(string)
                return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            }

        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        let outline = outlineWidth(for: label.fontSize)
        let widest = lines.map(\.width).max() ?? 0
        return Layout(
            lines: lines,
            ascent: ascent,
            lineHeight: lineHeight,
            outline: outline,
            size: CGSize(
                width: widest + outline * 2,
                height: CGFloat(lines.count) * lineHeight + outline * 2
            )
        )
    }

    static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }
}
