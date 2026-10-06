import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NeechanCore

@Suite("Image edit rendering")
struct ImageEditRendererTests {
    private let black = ThemeColor(red: 0, green: 0, blue: 0)
    private let red = ThemeColor(red: 1, green: 0, blue: 0)

    private func quadrantsPNG(width: Int = 80, height: Int = 40) throws -> Data {
        try ImageFactory.encode(ImageFactory.quadrants(width: width, height: height), as: "public.png")
    }

    private func export(_ data: Data, _ change: (inout ImageEdit) -> Void = { _ in }) throws -> ImageEditOutput {
        let source = try #require(ImageEditSource(data: data))
        var edit = ImageEdit(uprightSize: source.uprightSize)
        change(&edit)
        return try ImageEditRenderer.export(data, edit: edit)
    }

    // MARK: Reading the source

    @Test("an EXIF-rotated photo is edited upright")
    func exifUpright() throws {
        // Stored landscape, marked "turn clockwise to view": upright, the
        // stored top-left (red) is top-right, and the stored bottom-left
        // (blue) is top-left.
        let stored = try ImageFactory.quadrants(width: 40, height: 20)
        let data = try ImageFactory.encode(stored, as: "public.jpeg", properties: [kCGImagePropertyOrientation: 6])

        let source = try #require(ImageEditSource(data: data))
        #expect(source.uprightSize == PixelSize(width: 20, height: 40))

        let upright = try #require(ImageEditSource.decodeUpright(data, maxPixelSize: nil))
        let pixels = try PixelProbe(upright)
        #expect(pixels.width == 20 && pixels.height == 40)
        #expect(pixels[15, 5].isClose(to: .red))
        #expect(pixels[5, 5].isClose(to: .blue))
    }

    @Test("an animated GIF and a non-image cannot be edited")
    func notEditable() throws {
        let gif = try ImageFactory.animatedGIF(frames: 2)
        let source = try #require(ImageEditSource(data: gif))
        #expect(!source.isEditable)
        #expect(throws: ImageEditError.notEditable) {
            try ImageEditRenderer.export(gif, edit: ImageEdit(uprightSize: source.uprightSize))
        }

        #expect(ImageEditSource(data: Data("not a picture".utf8)) == nil)
        #expect(try #require(ImageEditSource(data: quadrantsPNG())).isEditable)
    }

    @Test("a reduced scale asks the decoder for only the size it needs")
    func decodeSize() {
        var edit = ImageEdit(uprightSize: PixelSize(width: 4000, height: 3000))
        #expect(ImageEditRenderer.decodeMaxPixelSize(for: edit) == 4000)
        edit.scalePercent = 25
        #expect(ImageEditRenderer.decodeMaxPixelSize(for: edit) == 1000)
        edit.scalePercent = 33
        #expect(ImageEditRenderer.decodeMaxPixelSize(for: edit) == 1320)
    }

    @Test("a thumbnail is upright and no larger than asked")
    func thumbnail() throws {
        let stored = try ImageFactory.quadrants(width: 400, height: 200)
        let data = try ImageFactory.encode(stored, as: "public.jpeg", properties: [kCGImagePropertyOrientation: 6])
        let thumbnail = try #require(ImageEditSource.decodeUpright(data, maxPixelSize: 100))
        #expect(thumbnail.height == 100)
        #expect(thumbnail.width == 50)
    }

    // MARK: Turning, mirroring, cropping

    @Test("an untouched edit reproduces the picture")
    func untouched() throws {
        let pixels = try PixelProbe(export(quadrantsPNG()).data)
        #expect(pixels.width == 80 && pixels.height == 40)
        #expect(pixels[10, 10] == .red)
        #expect(pixels[70, 10] == .green)
        #expect(pixels[10, 30] == .blue)
        #expect(pixels[70, 30] == .white)
    }

    @Test("a quarter turn moves the top-left colour to the top-right")
    func turn() throws {
        let pixels = try PixelProbe(export(quadrantsPNG()) { $0 = $0.turned(clockwise: true) }.data)
        #expect(pixels.width == 40 && pixels.height == 80)
        #expect(pixels[30, 10] == .red)
        #expect(pixels[10, 10] == .blue)
        #expect(pixels[30, 70] == .green)
    }

    @Test("mirroring swaps left and right")
    func mirror() throws {
        let pixels = try PixelProbe(export(quadrantsPNG()) { $0 = $0.mirroredAsSeen() }.data)
        #expect(pixels[10, 10] == .green)
        #expect(pixels[70, 10] == .red)
        #expect(pixels[10, 30] == .white)
    }

    @Test("cropping keeps only the chosen region")
    func crop() throws {
        let output = try export(quadrantsPNG()) { $0.crop = CGRect(x: 40, y: 0, width: 40, height: 20) }
        let pixels = try PixelProbe(output.data)
        #expect(output.pixelSize == PixelSize(width: 40, height: 20))
        #expect(pixels.count(.green, in: CGRect(x: 0, y: 0, width: 40, height: 20), tolerance: 0) == 800)
    }

    @Test(
        "the file has exactly the dimensions the geometry promised",
        arguments: [
            (101, 57, CGRect(x: 0, y: 0, width: 101, height: 57), 0, 33),
            (101, 57, CGRect(x: 3, y: 5, width: 50, height: 40), 1, 77),
            (640, 480, CGRect(x: 0, y: 0, width: 640, height: 480), 3, 10),
            (33, 99, CGRect(x: 1, y: 2, width: 31, height: 95), 2, 100),
        ]
    )
    func dimensions(width: Int, height: Int, crop: CGRect, turns: Int, percent: Int) throws {
        let data = try ImageFactory.encode(ImageFactory.quadrants(width: width, height: height), as: "public.jpeg")
        var edit = ImageEdit(uprightSize: PixelSize(width: width, height: height))
        edit.crop = crop
        edit.quarterTurns = turns
        edit.scalePercent = percent

        let output = try ImageEditRenderer.export(data, edit: edit)
        let promised = ImageEditGeometry(edit).outputPixelSize
        #expect(output.pixelSize == promised)
        let written = try #require(EXIFReaderProbe.pixelSize(of: output.data))
        #expect(written.width == promised.width && written.height == promised.height)
    }

    // MARK: Drawing

    @Test("a pen mark drawn before a turn stays on the same part of the photo")
    func penFollowsTurn() throws {
        let data = try ImageFactory.encode(ImageFactory.solid(width: 200, height: 100), as: "public.png")
        let mark = ImageEditMark(kind: .pen(points: [CGPoint(x: 20, y: 20)], width: 12, color: black))

        let flat = try PixelProbe(export(data) { $0.marks = [mark] }.data)
        #expect(flat[20, 20].isClose(to: .black))

        let turned = try PixelProbe(export(data) { edit in
            edit.marks = [mark]
            edit = edit.turned(clockwise: true)
        }.data)
        // Upright (20, 20) in a 200×100 photo is (100 − 20, 20) once turned.
        #expect(turned[80, 20].isClose(to: .black))
        #expect(turned[20, 20] == .white)
    }

    @Test("an arrow is drawn from its start to its head")
    func arrow() throws {
        let data = try ImageFactory.encode(ImageFactory.solid(width: 200, height: 100), as: "public.png")
        let mark = ImageEditMark(
            kind: .arrow(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), width: 6, color: black)
        )
        let pixels = try PixelProbe(export(data) { $0.marks = [mark] }.data)
        #expect(pixels[25, 50].isClose(to: .black))
        #expect(pixels[176, 50].isClose(to: .black))
        // The head is wider than the shaft.
        #expect(pixels[166, 55].isClose(to: .black))
        #expect(pixels[100, 56] == .white)
    }

    @Test("pixelate makes every pixel within a block the same")
    func pixelate() throws {
        let data = try ImageFactory.encode(ImageFactory.gradient(width: 96, height: 96), as: "public.png")
        let block = ImageEditStrokes.pixelBlock(for: PixelSize(width: 96, height: 96))
        #expect(block == 8)

        let mark = ImageEditMark(
            kind: .pixelate(points: [CGPoint(x: 0, y: 48), CGPoint(x: 96, y: 48)], width: 400)
        )
        let original = try PixelProbe(data)
        let pixels = try PixelProbe(export(data) { $0.marks = [mark] }.data)

        for blockY in stride(from: 0, to: 96, by: 8) {
            for blockX in stride(from: 0, to: 96, by: 8) {
                let first = pixels[blockX, blockY]
                for y in blockY..<(blockY + 8) {
                    for x in blockX..<(blockX + 8) where pixels[x, y] != first {
                        Issue.record("block at \(blockX),\(blockY) is not flat at \(x),\(y)")
                        return
                    }
                }
            }
        }
        #expect(original[1, 1] != original[6, 6])
    }

    @Test("pixelation only covers where it was brushed")
    func pixelateBrushOnly() throws {
        let data = try ImageFactory.encode(ImageFactory.gradient(width: 96, height: 96), as: "public.png")
        let mark = ImageEditMark(kind: .pixelate(points: [CGPoint(x: 20, y: 20)], width: 16))
        let original = try PixelProbe(data)
        let pixels = try PixelProbe(export(data) { $0.marks = [mark] }.data)
        #expect(pixels[90, 90] == original[90, 90])
        #expect(pixels[17, 17] == pixels[22, 22])
    }

    @Test("a label is drawn where it was placed, even after a turn")
    func label() throws {
        let data = try ImageFactory.encode(ImageFactory.solid(width: 200, height: 100), as: "public.png")
        let label = ImageEditLabel(text: "HH", center: CGPoint(x: 40, y: 30), fontSize: 30, color: red)
        let mark = ImageEditMark(kind: .label(label))

        let pixels = try PixelProbe(export(data) { edit in
            edit.marks = [mark]
            edit = edit.turned(clockwise: true)
        }.data)
        // Upright (40, 30) is (100 − 30, 40) = (70, 40) once turned.
        let around = CGRect(x: 70 - 25, y: 40 - 20, width: 50, height: 40)
        #expect(pixels.count(.red, in: around) > 50)
        #expect(pixels.count(.red, in: CGRect(x: 0, y: 120, width: 100, height: 80)) == 0)
    }

    // MARK: The file

    @Test("a PNG stays PNG, a photo becomes JPEG, and the name and type follow")
    func formats() throws {
        let png = try export(quadrantsPNG()) { $0 = $0.turned(clockwise: true) }
        #expect(png.mimeType == "image/png")
        #expect(EXIFReaderProbe.typeIdentifier(of: png.data) == "public.png")
        #expect(png.fileName(replacingExtensionOf: "screen.png") == "screen.png")

        let jpegData = try ImageFactory.encode(ImageFactory.quadrants(width: 80, height: 40), as: "public.jpeg")
        let jpeg = try export(jpegData) { $0 = $0.turned(clockwise: true) }
        #expect(jpeg.mimeType == "image/jpeg")
        #expect(jpeg.fileExtension == "jpg")
        #expect(EXIFReaderProbe.typeIdentifier(of: jpeg.data) == "public.jpeg")
        #expect(jpeg.fileName(replacingExtensionOf: "photo.heic") == "photo.jpg")
        #expect(jpeg.fileName(replacingExtensionOf: "noextension") == "noextension.jpg")
    }

    @Test("a source with transparency stays PNG and keeps it")
    func transparency() throws {
        let tiff = try ImageFactory.encode(ImageFactory.halfTransparent(width: 40, height: 20), as: "public.tiff")
        let output = try export(tiff) { $0.scalePercent = 50 }
        #expect(output.mimeType == "image/png")
        let pixels = try PixelProbe(output.data)
        #expect(pixels[15, 5].alpha == 0)
        #expect(pixels[5, 5].isClose(to: .red))
    }

    @Test("the written file carries no location, camera data or orientation")
    func noMetadata() throws {
        let stored = try ImageFactory.quadrants(width: 40, height: 20)
        let data = try ImageFactory.encode(stored, as: "public.jpeg", properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 37.62, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
        ])
        let before = try #require(EXIFReaderProbe.properties(of: data))
        #expect(before[kCGImagePropertyGPSDictionary] != nil)

        let output = try export(data) { $0.scalePercent = 90 }
        let after = try #require(EXIFReaderProbe.properties(of: output.data))
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect((after[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        // Upright already, so it reads the right way with no orientation.
        #expect(output.pixelSize == PixelSize(width: 18, height: 36))
    }

    // MARK: Preview

    @Test("the preview shows the whole turned picture while cropping")
    func previewUncropped() throws {
        let base = try ImageFactory.quadrants(width: 80, height: 40)
        var edit = ImageEdit(uprightSize: PixelSize(width: 80, height: 40))
        edit.crop = CGRect(x: 0, y: 0, width: 40, height: 20)
        edit = edit.turned(clockwise: true)

        let size = ImageEditRenderer.canvasSize(for: edit, pixelScale: 0.5, cropped: false)
        #expect(size == PixelSize(width: 20, height: 40))
        let image = try #require(ImageEditRenderer.render(base: base, edit: edit, canvasSize: size, cropped: false))
        let pixels = try PixelProbe(image)
        #expect(pixels[15, 5].isClose(to: .red))
        #expect(pixels[15, 35].isClose(to: .green))
    }

    @Test("a hidden mark is left out of the preview")
    func hiddenMark() throws {
        let base = try ImageFactory.solid(width: 100, height: 100)
        let mark = ImageEditMark(kind: .pen(points: [CGPoint(x: 50, y: 50)], width: 20, color: black))
        var edit = ImageEdit(uprightSize: PixelSize(width: 100, height: 100))
        edit.marks = [mark]
        let size = PixelSize(width: 100, height: 100)

        let shown = try PixelProbe(try #require(ImageEditRenderer.render(base: base, edit: edit, canvasSize: size)))
        let hidden = try PixelProbe(
            try #require(ImageEditRenderer.render(base: base, edit: edit, canvasSize: size, hiding: mark.id))
        )
        #expect(shown[50, 50].isClose(to: .black))
        #expect(hidden[50, 50] == .white)
    }
}
